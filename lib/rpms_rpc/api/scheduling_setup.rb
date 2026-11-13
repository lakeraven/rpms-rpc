# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # The site's scheduling setup that decides where an appointment may go: the
  # access types a block can carry, the holidays, each clinic's booking
  # rules, and whether check-in creates the PCC visit. The BSDX RPCs answer
  # none of these (the scheduling client read them with BMX SQL). Reads use
  # DDR LISTER (LISTC^DDR) and DDR GETS ENTRY DATA (GETSC^DDR2). Holiday add
  # and remove use DDR FILER (FILEC^DDR3): the only writer of HOLIDAY (#40.5)
  # is the interactive GO^SDHOL, and no #8994 entry reaches it (rpms-rpc#418).
  # mark_overbook files OVERBOOK (#44.003 field 9) with DDR FILER too, as
  # BPRM sets it after MAKE^BSDAPI.
  # Those RPCs are in CIAV VUECENTRIC, not BSDXRPC, and each method binds it
  # for the call and restores the caller's option afterward.
  #
  # The reply shapes are what a live rpms-ydb 7c3119b build answered the
  # scheduler persona (2026-10-30).
  module SchedulingSetup
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    ACCESS_TYPE_FILE = "9002018.35"
    HOLIDAY_FILE = "40.5"
    CANCELLED_BY = { "PC" => :patient, "PCA" => :patient, "C" => :clinic, "CA" => :clinic }.freeze
    HOSPITAL_LOCATION_FILE = 44
    # #9009017.2, the hospital location's IHS scheduling companion entry.
    # Field .09 is CREATE VISIT AT CHECK-IN, a set of codes. CHECKIN^BSDX25
    # compares the external value to "YES" (BSDX25.m:138) before it creates
    # the PCC visit.
    IHS_CLINIC_FILE = "9009017.2"
    CREATE_VISIT_AT_CHECKIN_FIELD = ".09"

    # HOSPITAL LOCATION (#44) fields a booking depends on: 1914 HOUR CLINIC
    # DISPLAY BEGINS, 1918.5 SCHEDULE ON HOLIDAYS? (Y or empty), 2002 MAX # DAYS
    # FOR FUTURE BOOKING, 2500 PROHIBIT ACCESS TO CLINIC? (Y or empty), 2505
    # INACTIVATE DATE, 2506 REACTIVATE DATE, 1916 PRINCIPAL CLINIC.
    CLINIC_FIELDS = { display_begins: "1914", schedule_on_holidays: "1918.5", max_future_days: "2002",
                      prohibit_access: "2500", inactivate_date: "2505", reactivate_date: "2506",
                      principal_clinic: "1916" }.freeze
    # CLINIC STOP (#40.7), and the clinic's own stop, #44 field 8 STOP CODE NUMBER.
    CLINIC_STOP_FILE = "40.7"
    STOP_CODE_FIELD = "8"
    # PRIVILEGED USER (#44 field 2501), a multiple of NEW PERSON pointers.
    PRIVILEGED_USER_FILE = "44.04"
    # BSDX RESOURCE USER, a user's rights on a resource.
    RESOURCE_USER_FILE = "9002018.15"
    # PATIENT (#44.003), a clinic appointment's patient entry under its time.
    CLINIC_APPOINTMENT_FILE = "44.003"
    # APPOINTMENT (#2.98), the patient's appointment multiple.
    PATIENT_APPOINTMENT_FILE = "2.98"

    # A clinic's scheduling settings, as BPRM's clinic configuration shows and
    # changes them (lakeraven-ehr#984). Each key names its HOSPITAL LOCATION
    # (#44) field, or its CLINIC SETUP PARAMETERS (#9009017.2) field, and how
    # the value is held: :int a whole number, :flag a set of codes with a yes
    # and a no (or blank) code, :pointer an entry of another file.
    CLINIC_SETTINGS = {
      abbreviation: { file: 44, field: "1", kind: :text },
      institution: { file: 44, field: "3", kind: :pointer },
      division: { file: 44, field: "3.5", kind: :pointer },
      stop_code: { file: 44, field: "8", kind: :pointer },
      length_minutes: { file: 44, field: "1912", kind: :int },
      variable_length: { file: 44, field: "1913", kind: :flag, yes: "V", no: "@" },
      display_begins: { file: 44, field: "1914", kind: :int },
      increments_per_hour: { file: 44, field: "1917", kind: :int },
      overbooks_per_day: { file: 44, field: "1918", kind: :int },
      schedule_on_holidays: { file: 44, field: "1918.5", kind: :flag, yes: "Y", no: "@" },
      allowable_no_shows: { file: 44, field: "2001", kind: :int },
      max_future_days: { file: 44, field: "2002", kind: :int },
      prohibit_access: { file: 44, field: "2500", kind: :flag, yes: "Y", no: "@" },
      non_count: { file: 44, field: "2502", kind: :flag, yes: "Y", no: "N" },
      include_on_file_room_lists: { file: 44, field: "2502.5", kind: :flag, yes: "1", no: "0" },
      meets_at_facility: { file: 44, field: "2504", kind: :flag, yes: "Y", no: "N" },
      no_show_letter: { file: 44, field: "2508", kind: :pointer },
      pre_appointment_letter: { file: 44, field: "2509", kind: :pointer },
      clinic_cancellation_letter: { file: 44, field: "2510", kind: :pointer },
      appointment_cancellation_letter: { file: 44, field: "2511", kind: :pointer },
      no_show_waiting_days: { file: IHS_CLINIC_FILE, field: ".03", kind: :int },
      create_visit_at_checkin: { file: IHS_CLINIC_FILE, field: ".09", kind: :flag, yes: "1", no: "0" },
      visit_provider_required: { file: IHS_CLINIC_FILE, field: ".14", kind: :flag, yes: "1", no: "0" }
    }.freeze
    # DISPLAY INCREMENTS PER HOUR (#44 field 1917) codes: the code is the
    # number of increments in an hour (1 is 60 minutes, 4 is 15).
    INCREMENTS_PER_HOUR = [ 1, 2, 3, 4, 6 ].freeze
    # LETTER (#407.5) field 1 TYPE, and the #44 field that names a clinic's
    # letter of that type (each field's screen allows only its type).
    LETTER_FILE = "407.5"
    LETTER_TYPES = { "N" => :no_show, "P" => :pre_appointment, "C" => :clinic_cancellation,
                     "A" => :appointment_cancellation }.freeze
    # PROVIDER (#44 field 2600), the clinic's providers: .01 PROVIDER, .02
    # DEFAULT PROVIDER.
    CLINIC_PROVIDER_FILE = "44.1"
    # BSDX RESOURCE GROUP and its RESOURCE multiple.
    RESOURCE_GROUP_FILE = "9002018.2"
    RESOURCE_GROUP_ITEM_FILE = "9002018.21"

    # How many entries one DDR LISTER call asks for; a longer list is read on
    # from the MORE marker.
    PAGE = 100

    # HOLIDAY (#40.5) field 2 NAME. The unit contract refuses a longer name
    # before any RPC; FileMan would refuse it on the write.
    HOLIDAY_NAME_MAX = 30

    # Every BSDX ACCESS TYPE (#9002018.35) with its .01 ACCESS TYPE NAME, .02
    # INACTIVE and .08 PREVENT ACCESS. A block whose access type prevents access
    # takes no appointment (rpms-ux S-SCH-04.2). An unset flag reads as false.
    # color is "#RRGGBB" from .05 RED, .06 GREEN and .07 BLUE (0-255 each), the
    # colour a schedule shows its blocks in, or nil when any is unset.
    # Returns [{ id:, name:, inactive:, prevent_access:, color: }], by name. A
    # failed read raises Client::RpcError.
    def access_types
      list(ACCESS_TYPE_FILE, "@;.01;.02I;.08I;.05;.06;.07").map do |entry|
        name, inactive, prevent, *rgb = entry[:pieces]
        color = rgb.size == 3 && rgb.all? { |c| c.to_s.match?(/\A\d{1,3}\z/) && c.to_i <= 255 } ? format("#%02X%02X%02X", *rgb.map(&:to_i)) : nil
        { id: entry[:ien].to_i, name: name, inactive: inactive == "1", prevent_access: prevent == "1", color: color }
      end
    end
    shape :access_types, resource: "appointments", verb: "GET", path: "/appointments/access-types"

    # The HOLIDAY (#40.5) entries from start_date through end_date, by date.
    # Returns [{ date: Date, name: }]. A failed read raises Client::RpcError:
    # no reply, "[Errors]", or a reply with no "[Data]" line. "[Data]" with
    # no rows is an empty list.
    def holidays(start_date:, end_date:)
      first = fm_date(start_date)
      last = fm_date(end_date)
      # FROM is exclusive (LIST^DIC), so the walk starts one below the first
      # date: 3261101 - 1 is 3261100, which collates just before it.
      entries = list(HOLIDAY_FILE, "@;.01I;2", xref: "B", from: (first - 1).to_s, stop: ->(e) { e[:pieces].first.to_i > last })
      entries.map { |e| { date: FilemanDateParser.parse_date(e[:pieces][0]), name: e[:pieces][1] } }
    end
    shape :holidays, resource: "appointments", verb: "GET", path: "/appointments/holidays"

    # Whether the user holds the master overbook right on the resource: BSDX
    # RESOURCE USER (#9002018.15) .06 MASTEROVERBOOK for the entry naming the
    # resource (.01) and the user (.02). A master overbook may book past the
    # clinic's overbooks-per-day maximum and outside the resource's blocks
    # (rpms-ux S-SCH-01.9 to 01.11). BSDX RESOURCES does not carry it.
    # false when no entry names them. A failed read raises Client::RpcError.
    def master_overbook?(resource_id:, duz:)
      list(RESOURCE_USER_FILE, "@;.01I;.02I;.06I").any? do |entry|
        resource, user, master = entry[:pieces]
        resource.to_i == resource_id.to_i && user.to_i == duz.to_i && master == "1"
      end
    end
    shape :master_overbook?, resource: "appointments", verb: "GET", path: "/appointments/master-overbook"

    # Marks a booked appointment as an overbook: OVERBOOK (#44.003 field 9)
    # set to "O" on the clinic's entry for the patient at that time. BPRM sets
    # it itself after MAKE^BSDAPI (BSD_SetPatientAppointmentV4M); neither
    # MAKE^BSDAPI nor BSDX ADD NEW APPOINTMENT does, so a booking through BSDX
    # is unmarked until this runs (lakeraven-ehr#603). It is a plain FileMan
    # write of one set-of-codes field with no cross-reference, so it goes
    # through DDR FILER (FILE^DIE), like the reads here in CIAV VUECENTRIC.
    # The clinic's own overbook count reads these marks (SDMM1, SDM2).
    #
    # Setting it again is harmless.
    # Returns { success: true }, { success: false, error: } when the clinic
    # holds no appointment for the patient then or FileMan refuses, or nil when
    # the broker gives no reply.
    def mark_overbook(hospital_location_id:, start_time:, patient_dfn:)
      file_clinic_entry(hospital_location_id, start_time, patient_dfn, "9", "O")
    end
    shape :mark_overbook, resource: "appointments", verb: "POST", path: "/patients/{patient_dfn}/appointments/mark-overbook"

    # The times on a clinic's day that hold an overbook (rpms-ux S-SCH-05.3):
    # OVERBOOK (#44.003 field 9) on the patient's entry at that time. The
    # BSDX reads do not carry it. false when the clinic holds no entry for the
    # patient then, as after a cancellation. A failed read raises
    # Client::RpcError.
    def overbook?(hospital_location_id:, start_time:, patient_dfn:)
      clinic = hospital_location_id.to_s
      raise ArgumentError, "hospital_location_id must be a positive integer" unless clinic.match?(/\A[1-9]\d*\z/)

      at = iens_time(start_time)
      entries = list(CLINIC_APPOINTMENT_FILE, "@;.01I;9I", iens: ",#{at},#{clinic},")
      entries.any? { |e| e[:pieces][0].to_i == patient_dfn.to_i && e[:pieces][1] == "O" }
    end
    shape :overbook?, resource: "appointments", verb: "GET", path: "/patients/{patient_dfn}/appointments/overbook"

    # Who cancelled the patient's appointment at that time (S-SCH-05.3): "PC"
    # or "PCA" is the patient and "C" or "CA" the clinic, by STATUS (#2.98
    # field 3); the BSDX reads say only that it was cancelled. Returns :patient,
    # :clinic, or nil for any other status. A failed read raises
    # Client::RpcError.
    def cancelled_by(start_time:, patient_dfn:)
      iens = "#{iens_time(start_time)},#{patient_dfn.to_i},"
      read = in_context { DdrFileman.gets_entry(file: PATIENT_APPOINTMENT_FILE, iens: iens, fields: "3", flags: "I") }
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{PATIENT_APPOINTMENT_FILE}" if read.nil?
      return nil if read[:error]

      CANCELLED_BY[read[:fields].dig("3", :internal).to_s]
    end
    shape :cancelled_by, resource: "appointments", verb: "GET", path: "/patients/{patient_dfn}/appointments/cancelled-by"

    # Files a booked appointment's note on the clinic: OTHER (#44.003 field 3),
    # the copy MAKE^BSDAPI files at booking (its "OI") and the clinic's lists
    # print. BSDX EDIT APPOINTMENT changes only the BSDX APPOINTMENT note, so
    # a corrected note reaches the clinic only through this (rpms-ux S-SCH-09.1).
    # A plain free-text field (1 to 150 characters, no cross-reference), filed
    # with DDR FILER. A blank note deletes it ("@"). Returns as mark_overbook.
    def set_clinic_note(hospital_location_id:, start_time:, patient_dfn:, note:)
      text = note.to_s
      raise ArgumentError, "a clinic note is at most 150 characters" if text.length > 150

      file_clinic_entry(hospital_location_id, start_time, patient_dfn, "3", text.empty? ? "@" : text)
    end
    shape :set_clinic_note, resource: "appointments", verb: "PUT", path: "/patients/{patient_dfn}/appointments/clinic-note"

    # Files a cancelled or no-show appointment's remarks: CANCELLATION REMARKS
    # (#2.98 field 17) on the patient's appointment at that time, as CANCEL^BSDAPI
    # files them when it cancels (rpms-ux S-SCH-09.3). No BSDX RPC edits them.
    # A plain free-text field with no cross-reference, filed with DDR FILER.
    # Remarks are 3 to 160 characters (the rule BSDX and BPRM keep).
    # Returns { success: true }, { success: false, error: }, or nil.
    def set_cancellation_remarks(patient_dfn:, start_time:, remarks:)
      text = remarks.to_s
      raise ArgumentError, "remarks are 3 to 160 characters" unless (3..160).cover?(text.length)
      raise ArgumentError, "patient_dfn must be a positive integer" unless patient_dfn.to_s.match?(/\A[1-9]\d*\z/)

      row = { file: PATIENT_APPOINTMENT_FILE, field: "17", iens: "#{iens_time(start_time)},#{patient_dfn},", value: text }
      filed = in_context { DdrFileman.filer(mode: "EDIT", rows: [ row ]) }
      return nil if filed.nil?

      filed[:success] ? { success: true } : { success: false, error: Array(filed[:errors]).join(" ") }
    end
    shape :set_cancellation_remarks, resource: "appointments", verb: "PUT", path: "/patients/{patient_dfn}/appointments/cancellation-remarks"
    # Add a HOLIDAY (#40.5) row. The only writer is the interactive GO^SDHOL
    # (DIC/DIE); no #8994 entry reaches it (rpms-rpc#418, resolution 2), so
    # this is DDR FILER ADD (FILEC^DDR3). .01 DATE is DINUM and field 2 is
    # NAME. The B xref is FileMan's and is maintained on the write. GO^SDHOL's
    # prompts and any defaults it would stuff are not run. A blank name, a
    # name over 30 characters, or a name that after strip contains "^", a
    # control character, or is exactly "@", is { success: false, error:
    # :invalid } and sends no RPC. Ordinary text still files. DDR FILER's
    # error text, including a reply with no [Data] marker, is :filer_failed
    # because filer success is false. nil when FILER gives no reply.
    def add_holiday(date:, name:)
      day = fileman_day(date)
      return invalid("date must be a Date") unless day

      text = holiday_name(name)
      return text unless text.is_a?(String)

      filed = in_context do
        DdrFileman.filer(mode: "ADD", rows: [
          { file: HOLIDAY_FILE, field: ".01", iens: "+1,", value: day },
          { file: HOLIDAY_FILE, field: "2", iens: "+1,", value: text }
        ], iens: { 1 => day })
      end
      filer_outcome(filed)
    end
    shape :add_holiday, resource: "appointments", verb: "POST", path: "/appointments/holiday"

    # Remove the HOLIDAY (#40.5) row for a date. DDR LISTER walks the B xref
    # (the file's only xref) FROM one below that internal date, the way
    # holidays does. LIST^DIC's PART match does not find a numeric FileMan
    # date on that index, and FROM is exclusive, so the next row is the first
    # holiday after the day before. The row is deleted only when its .01 is
    # exactly that date. Anything else, including "[Data]" with no rows, is
    # { success: false, error: :not_found } and files nothing. A failed
    # lookup (no reply, "[Errors]", or a reply with no "[Data]" line)
    # raises Client::RpcError rather than reporting not-found. DDR FILER
    # EDIT sets .01 to "@", which is FileMan's delete. A FILER reply with
    # no [Data] is :filer_failed because filer success is false. GO^SDHOL
    # is not called.
    def remove_holiday(date)
      day = fileman_day(date)
      return invalid("date must be a Date") unless day

      in_context do
        # One row is enough: B is ordered by the date, and FROM excludes the
        # day before, so the next row is this date or a later holiday.
        listed = DdrFileman.lister(file: HOLIDAY_FILE, fields: "@;.01I", flags: "IP", max: 1, xref: "B",
                                   from: (day.to_i - 1).to_s)
        raise Client::RpcError, "DDR LISTER gave no reply for HOLIDAY #40.5" if listed.nil?
        raise Client::RpcError, "DDR LISTER refused HOLIDAY #40.5" if listed[:error]

        entry = listed[:entries].find { |e| e[:pieces].first.to_s == day }
        return { success: false, error: :not_found, message: "no holiday on that date" } unless entry

        ien = entry[:ien].to_s
        raise Client::RpcError, "DDR LISTER returned a holiday row with no IEN" unless ien.match?(/\A[1-9]\d*\z/)

        filed = DdrFileman.filer(mode: "EDIT", rows: [
          { file: HOLIDAY_FILE, field: ".01", iens: "#{ien},", value: "@" }
        ])
        filer_outcome(filed)
      end
    end
    shape :remove_holiday, resource: "appointments", verb: "DELETE", path: "/appointments/holiday"

    # One clinic's booking rules from HOSPITAL LOCATION (#44), by its IEN (the
    # hospital_location_id of a Scheduling.resources row). Returns
    # { id:, display_begins:, schedule_on_holidays:, max_future_days:,
    #   prohibit_access:, privileged_users:, inactivate_date:, reactivate_date: }: display_begins
    # is an hour (0-23) and max_future_days a count, each nil when unset; the
    # dates are Date or nil. privileged_users is the DUZs a clinic that
    # prohibits access lets in: its own PRIVILEGED USERs and its principal
    # clinic's, as RPMS's own scheduling checks them (SDM1.m:33); read only
    # when the clinic prohibits access, [] otherwise.
    # nil for an IEN that is not a number. A failed
    # read, or an IEN with no entry, raises Client::RpcError.
    def clinic_rules(hospital_location_id)
      ien = hospital_location_id.to_s
      return nil unless ien.match?(/\A[1-9]\d*\z/)

      got = in_context do
        DdrFileman.gets_entry(file: HOSPITAL_LOCATION_FILE, iens: "#{ien},", fields: CLINIC_FIELDS.values.join(";"), flags: "I")
      end
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for #44 #{ien}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused #44 #{ien}" if got[:error]

      value = ->(key) { got[:fields].dig(CLINIC_FIELDS[key], :internal).to_s }
      { id: ien.to_i,
        display_begins: integer_or_nil(value.(:display_begins)),
        schedule_on_holidays: value.(:schedule_on_holidays) == "Y",
        max_future_days: integer_or_nil(value.(:max_future_days)),
        prohibit_access: value.(:prohibit_access) == "Y",
        privileged_users: value.(:prohibit_access) == "Y" ? privileged_users(ien, value.(:principal_clinic)) : [],
        inactivate_date: date_or_nil(value.(:inactivate_date)),
        reactivate_date: date_or_nil(value.(:reactivate_date)) }
    end
    shape :clinic_rules, resource: "appointments", verb: "GET", path: "/appointments/clinic-rules"

    # Whether CHECKIN^BSDX25 (BSDX CHECKIN APPOINTMENT) creates the PCC visit
    # for this clinic. It does so through GETVISIT^BSDAPI4 only when the
    # external value of #9009017.2 field .09 is "YES" (BSDX25.m:138:
    # I $$GET1^DIQ(9009017.2,+BSDXC("HOS LOC"),.09)'="YES" Q). #9009017.2 is
    # the hospital location's IHS scheduling companion entry. .09 (CREATE
    # VISIT AT CHECK-IN) is a set of codes whose internal "1" is external
    # "YES" (observed live). true only when the .09 row's internal is "1" and
    # its external is "YES"; otherwise false. A reply with no .09 field row
    # raises Client::RpcError (fail closed). A clinic with no #9009017.2
    # entry raises Client::RpcError, as do a nil or error reply. DDR GETS ENTRY
    # DATA for a missing entry answers the bare reply ["[ERROR]"] (GETS^DIQ
    # raises DIALOG 601, DDR2 writes only [ERROR]), so over the wire a missing
    # entry cannot be told from another failure. That is deliberate (fail
    # closed). M itself treats a missing entry as no visit, so a host that
    # gets the raise must not assume check-in will create the visit. nil for
    # an IEN that is not a positive integer, and no RPC is sent.
    def creates_visit_at_checkin(hospital_location_id)
      ien = hospital_location_id.to_s
      return nil unless ien.match?(/\A[1-9]\d*\z/)

      got = in_context do
        DdrFileman.gets_entry(file: IHS_CLINIC_FILE, iens: "#{ien},", fields: CREATE_VISIT_AT_CHECKIN_FIELD, flags: "IE")
      end
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{IHS_CLINIC_FILE} #{ien}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused ##{IHS_CLINIC_FILE} #{ien}" if got[:error]

      row = got[:fields][CREATE_VISIT_AT_CHECKIN_FIELD]
      raise Client::RpcError, "DDR GETS ENTRY DATA for ##{IHS_CLINIC_FILE} #{ien} is missing the #{CREATE_VISIT_AT_CHECKIN_FIELD} row" if row.nil?

      row[:internal].to_s == "1" && row[:external].to_s == "YES"
    end
    shape :creates_visit_at_checkin, resource: "appointments", verb: "GET", path: "/appointments/creates-visit-at-checkin"

    # Every CLINIC STOP (#40.7): .01 NAME, 1 CODE and 2 INACTIVE DATE, by IEN.
    # A check-in at a clinic set to use several clinic stop codes
    # (#9009017.2 .13) names one: BSDX CHECKIN APPOINTMENT takes its IEN as
    # the clinic code. Neither the clinic's setup nor BSDX names which stops a
    # clinic allows, so this is the whole file; the caller leaves out the
    # inactive ones. Returns [{ id:, name:, code:, inactive_date: }] with
    # inactive_date a Date or nil. A failed read raises Client::RpcError.
    def clinic_stops
      list(CLINIC_STOP_FILE, "@;.01;1;2I", xref: "#").map do |entry|
        name, code, inactive = entry[:pieces]
        { id: entry[:ien].to_i, name: name, code: code, inactive_date: date_or_nil(inactive.to_s) }
      end
    end
    shape :clinic_stops, resource: "appointments", verb: "GET", path: "/appointments/clinic-stops"

    # The clinic's own stop: HOSPITAL LOCATION (#44) field 8 STOP CODE NUMBER,
    # the CLINIC STOP IEN a check-in files the visit under when it names none
    # (BSDAPI4.m: IN("CLINIC CODE") defaults to it). Integer, or nil when the
    # clinic has none or the IEN is not a number. A failed read raises
    # Client::RpcError.
    def clinic_stop(hospital_location_id)
      ien = hospital_location_id.to_s
      return nil unless ien.match?(/\A[1-9]\d*\z/)

      got = in_context { DdrFileman.gets_entry(file: HOSPITAL_LOCATION_FILE, iens: "#{ien},", fields: STOP_CODE_FIELD, flags: "I") }
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for #44 #{ien}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused #44 #{ien}" if got[:error]

      integer_or_nil(got[:fields].dig(STOP_CODE_FIELD, :internal).to_s)
    end
    shape :clinic_stop, resource: "appointments", verb: "GET", path: "/appointments/clinic-stop"

    # A clinic's scheduling settings (lakeraven-ehr#984): the HOSPITAL
    # LOCATION (#44) fields and the CLINIC SETUP PARAMETERS (#9009017.2)
    # fields of CLINIC_SETTINGS, read with DDR GETS ENTRY DATA, and the
    # clinic's providers. Returns a Hash with :id, :name, every
    # CLINIC_SETTINGS key, :setup_entry (false when the clinic has no
    # #9009017.2 entry, whose three keys are then nil) and :providers
    # (clinic_providers). A whole number is an Integer or nil, a flag true or
    # false, a pointer { id:, name: } or nil. nil for an IEN that is not a
    # positive integer. A failed read, or an IEN with no #44 entry, raises
    # Client::RpcError.
    def clinic_settings(hospital_location_id)
      ien = positive_id(hospital_location_id)
      return nil unless ien

      fields = CLINIC_SETTINGS.select { |_, s| s[:file] == HOSPITAL_LOCATION_FILE }
      got = gets!(HOSPITAL_LOCATION_FILE, ien, ([ ".01" ] + fields.values.map { |s| s[:field] }).join(";"))
      setup_fields = CLINIC_SETTINGS.reject { |_, s| s[:file] == HOSPITAL_LOCATION_FILE }
      setup = in_context do
        DdrFileman.gets_entry(file: IHS_CLINIC_FILE, iens: "#{ien},", fields: setup_fields.values.map { |s| s[:field] }.join(";"), flags: "IE")
      end
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{IHS_CLINIC_FILE} #{ien}" if setup.nil?

      # A clinic with no #9009017.2 entry answers the bare [ERROR] (see creates_visit_at_checkin).
      setup_entry = !setup[:error]
      settings = { id: ien.to_i, name: got[:fields].dig(".01", :external).to_s }
      fields.each { |key, spec| settings[key] = setting_value(spec, got[:fields][spec[:field]]) }
      setup_fields.each { |key, spec| settings[key] = setup_entry ? setting_value(spec, setup[:fields][spec[:field]]) : nil }
      settings.merge(setup_entry: setup_entry, providers: clinic_providers(ien))
    end
    shape :clinic_settings, resource: "appointments", verb: "GET", path: "/appointments/clinic-settings"

    # Files changes to a clinic's scheduling settings. changes is a Hash of
    # CLINIC_SETTINGS keys: a whole number as an Integer (nil clears it), a
    # flag true or false, a pointer as the other file's IEN (nil clears it),
    # the abbreviation as text. An unknown key raises ArgumentError before
    # anything is sent.
    #
    # Each #44 field is filed on its own with DDR FILER (FILE^DIE) and the
    # "E" flag, so FileMan validates it as its own editor would: the field's
    # input transform and, for a pointer, its screen (a no-show letter must be
    # a LETTER of type N). LENGTH OF APP'T (1912) must be a multiple of the
    # minutes in one display increment (1917), and the two transforms each
    # check the other's stored value, so a field FileMan refuses is tried
    # once more after the rest are filed. #9009017.2 fields file the same way,
    # or are added with the entry when the clinic has none (its .01 is the
    # clinic, DINUM).
    #
    # Returns { success: true } when every field filed, or
    # { success: false, refused: { key => FileMan's message } } naming each
    # field that did not; the others are filed. nil when the broker gives no
    # reply.
    def update_clinic_settings(hospital_location_id, changes)
      ien = positive_id(hospital_location_id)
      raise ArgumentError, "hospital_location_id must be a positive integer" unless ien

      unknown = changes.keys - CLINIC_SETTINGS.keys
      raise ArgumentError, "unknown clinic settings: #{unknown.join(', ')}" unless unknown.empty?

      values = changes.to_h { |key, value| [ key, filed_value(key, CLINIC_SETTINGS[key], value) ] }
      setup = values.select { |key, _| CLINIC_SETTINGS[key][:file] == IHS_CLINIC_FILE }
      refused = {}
      unless setup.empty? || setup_entry?(ien)
        outcome = add_setup_entry(ien, setup)
        return nil if outcome.nil?

        setup.each_key { |key| refused[key] = outcome } unless outcome == true
        values = values.except(*setup.keys)
      end

      failed = file_settings(ien, values)
      return nil if failed.nil?

      # One may have been refused only for the other stored value (1912 and 1917).
      if failed.any? && failed.size < values.size
        failed = file_settings(ien, values.slice(*failed.keys))
        return nil if failed.nil?
      end
      refused.merge!(failed)
      refused.empty? ? { success: true } : { success: false, refused: refused }
    end
    shape :update_clinic_settings, resource: "appointments", verb: "PUT", path: "/appointments/clinic-settings"

    # Every LETTER (#407.5): .01 NAME and field 1 TYPE, as { id:, name:, type: }
    # with type :no_show, :pre_appointment, :clinic_cancellation or
    # :appointment_cancellation (nil for any other code), by name. A clinic's
    # letter of each type is one of these (clinic_settings). A failed read
    # raises Client::RpcError.
    def letters
      list(LETTER_FILE, "@;.01;1").map do |entry|
        name, type = entry[:pieces]
        { id: entry[:ien].to_i, name: name, type: LETTER_TYPES[type.to_s] }
      end
    end
    shape :letters, resource: "appointments", verb: "GET", path: "/appointments/letters"

    # A clinic's providers, PROVIDER (#44 field 2600): [{ id:, duz:, name:,
    # default: }] by name, id being the entry in the multiple. BSDX HOSPITAL
    # LOCATION names the first whose DEFAULT PROVIDER (.02) is YES as the
    # clinic's default provider. A failed read raises Client::RpcError.
    def clinic_providers(hospital_location_id)
      ien = positive_id(hospital_location_id)
      raise ArgumentError, "hospital_location_id must be a positive integer" unless ien

      list(CLINIC_PROVIDER_FILE, "@;.01I;.01E;.02I", iens: ",#{ien},").map do |entry|
        duz, name, default = entry[:pieces]
        { id: entry[:ien].to_i, duz: duz.to_i, name: name.to_s, default: default == "1" }
      end.sort_by { |p| p[:name] }
    end
    shape :clinic_providers, resource: "appointments", verb: "GET", path: "/appointments/clinic-providers"

    # Adds a provider to the clinic, or keeps the one already there, and makes
    # them the default when default is true (any other default is cleared
    # first, as DEFAULT PROVIDER's transform allows only one). The provider is
    # checked against the field's own screen with DDR VALIDATOR ($$SCREEN^SDUTL2:
    # an active user who may be a provider) before anything is filed.
    # Returns { success: true, id: } (the entry), { success: false, error: },
    # or nil when the broker gives no reply.
    def add_clinic_provider(hospital_location_id:, duz:, default: false)
      ien = positive_id(hospital_location_id)
      raise ArgumentError, "hospital_location_id must be a positive integer" unless ien
      raise ArgumentError, "duz must be a positive integer" unless positive_id(duz)

      existing = clinic_providers(ien).find { |p| p[:duz] == duz.to_i }
      unless existing
        check = in_context { DdrFileman.validate_field(file: CLINIC_PROVIDER_FILE, iens: "+1,#{ien},", field: ".01", value: "`#{duz.to_i}") }
        return nil if check.nil?
        return { success: false, error: "RPMS does not accept user #{duz} as a provider for this clinic" } unless check[:valid]

        added = in_context { DdrFileman.filer(mode: "ADD", rows: [ { file: CLINIC_PROVIDER_FILE, field: ".01", iens: "+1,#{ien},", value: duz.to_i.to_s } ]) }
        return nil if added.nil?
        return { success: false, error: Array(added[:errors]).join(" ") } unless added[:success]

        existing = { id: added[:iens][1].to_i }
      end
      return { success: true, id: existing[:id] } unless default

      outcome = set_default_provider(hospital_location_id: ien, entry_id: existing[:id])
      outcome && outcome[:success] ? { success: true, id: existing[:id] } : outcome
    end
    shape :add_clinic_provider, resource: "appointments", verb: "POST", path: "/appointments/clinic-provider"

    # Makes one of the clinic's providers its default: DEFAULT PROVIDER (.02)
    # NO on every other entry, then YES on this one, filed as internal codes
    # (FILE^DIE without "E", so the field's interactive transform is not run;
    # its cross-reference is). Returns { success: true }, { success: false,
    # error: }, or nil.
    def set_default_provider(hospital_location_id:, entry_id:)
      ien = positive_id(hospital_location_id)
      raise ArgumentError, "hospital_location_id must be a positive integer" unless ien

      providers = clinic_providers(ien)
      return { success: false, error: "no provider entry #{entry_id} on clinic #{ien}" } unless providers.any? { |p| p[:id] == entry_id.to_i }

      rows = providers.select { |p| p[:default] && p[:id] != entry_id.to_i }
                      .map { |p| { file: CLINIC_PROVIDER_FILE, field: ".02", iens: "#{p[:id]},#{ien},", value: "0" } }
      rows << { file: CLINIC_PROVIDER_FILE, field: ".02", iens: "#{entry_id.to_i},#{ien},", value: "1" }
      filer_result(in_context { DdrFileman.filer(mode: "EDIT", rows: rows) })
    end
    shape :set_default_provider, resource: "appointments", verb: "PUT", path: "/appointments/default-provider"

    # Removes a provider entry from the clinic (.01 set to "@", FileMan's
    # delete). Returns { success: true }, { success: false, error: }, or nil.
    def remove_clinic_provider(hospital_location_id:, entry_id:)
      ien = positive_id(hospital_location_id)
      entry = positive_id(entry_id)
      raise ArgumentError, "hospital_location_id and entry_id must be positive integers" unless ien && entry

      filer_result(in_context { DdrFileman.filer(mode: "EDIT", rows: [ { file: CLINIC_PROVIDER_FILE, field: ".01", iens: "#{entry},#{ien},", value: "@" } ]) })
    end
    shape :remove_clinic_provider, resource: "appointments", verb: "DELETE", path: "/appointments/clinic-provider"

    # The users a clinic's resource names in BSDX RESOURCE USER
    # (#9002018.15), with their rights on it: [{ id:, duz:, name:, overbook:,
    # modify_schedule:, modify_appointments:, master_overbook: }] by name.
    # These are BPRM's "clinic users". A failed read raises Client::RpcError.
    def resource_users(resource_id)
      resource = positive_id(resource_id)
      raise ArgumentError, "resource_id must be a positive integer" unless resource

      list(RESOURCE_USER_FILE, "@;.01I;.02I;.02E;.03I;.04I;.05I;.06I").filter_map do |entry|
        res, duz, name, overbook, schedule, appointments, master = entry[:pieces]
        next unless res.to_i == resource.to_i

        { id: entry[:ien].to_i, duz: duz.to_i, name: name.to_s, overbook: overbook == "1", modify_schedule: schedule == "1",
          modify_appointments: appointments == "1", master_overbook: master == "1" }
      end.sort_by { |u| u[:name] }
    end
    shape :resource_users, resource: "appointments", verb: "GET", path: "/appointments/resource-users"

    # Sets a resource user's master overbook right, MASTEROVERBOOK (.06),
    # which BSDX ADD/EDIT RESOURCEUSER does not file. Returns { success: true },
    # { success: false, error: }, or nil.
    def set_master_overbook(resource_user_id:, master:)
      id = positive_id(resource_user_id)
      raise ArgumentError, "resource_user_id must be a positive integer" unless id

      row = { file: RESOURCE_USER_FILE, field: ".06", iens: "#{id},", value: master ? "1" : "0" }
      filer_result(in_context { DdrFileman.filer(mode: "EDIT", rows: [ row ]) })
    end
    shape :set_master_overbook, resource: "appointments", verb: "PUT", path: "/appointments/master-overbook"

    # Every BSDX RESOURCE GROUP (#9002018.2) with its resources (the
    # RESOURCE multiple, #9002018.21): [{ id:, name:, inactive_date:,
    # resources: [{ id:, resource_id:, name: }] }] by name, id in resources
    # being the entry in the multiple. Unlike BSDX RESOURCE GROUPS BY USER,
    # it lists every group, as table maintenance does. A failed read raises
    # Client::RpcError.
    def resource_groups
      list(RESOURCE_GROUP_FILE, "@;.01;.02I").map do |entry|
        name, inactive = entry[:pieces]
        items = list(RESOURCE_GROUP_ITEM_FILE, "@;.01I;.01E", iens: ",#{entry[:ien]},").map do |item|
          resource, resource_name = item[:pieces]
          { id: item[:ien].to_i, resource_id: resource.to_i, name: resource_name.to_s }
        end
        { id: entry[:ien].to_i, name: name.to_s, inactive_date: date_or_nil(inactive.to_s), resources: items.sort_by { |i| i[:name] } }
      end
    end
    shape :resource_groups, resource: "appointments", verb: "GET", path: "/appointments/resource-groups"

    private

    def positive_id(value)
      text = value.to_s
      text.match?(/\A[1-9]\d*\z/) ? text : nil
    end

    def gets!(file, ien, fields)
      got = in_context { DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE") }
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{file} #{ien}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused ##{file} #{ien}" if got[:error]

      got
    end

    # A CLINIC_SETTINGS field's value as clinic_settings returns it.
    def setting_value(spec, row)
      internal = row&.dig(:internal).to_s
      case spec[:kind]
      when :int then integer_or_nil(internal)
      when :flag then internal == spec[:yes]
      when :pointer then internal.empty? ? nil : { id: internal.to_i, name: row[:external].to_s }
      else internal
      end
    end

    # A CLINIC_SETTINGS value as FILE^DIE takes it with the "E" flag: "@"
    # deletes, a pointer is "`IEN" (FileMan's lookup by number).
    def filed_value(key, spec, value)
      case spec[:kind]
      when :int
        return "@" if value.nil?
        raise ArgumentError, "#{key} must be a whole number" unless value.is_a?(Integer) && value >= 0

        value.to_s
      when :flag
        raise ArgumentError, "#{key} must be true or false" unless [ true, false ].include?(value)

        value ? spec[:yes] : spec[:no]
      when :pointer
        return "@" if value.nil?
        raise ArgumentError, "#{key} must be an IEN" unless positive_id(value)

        "`#{value}"
      else
        text = value.to_s.strip
        return "@" if text.empty?
        raise ArgumentError, "#{key} cannot contain ^ or a control character" if text.include?("^") || text.match?(/[[:cntrl:]]/)

        text
      end
    end

    # Files each value on its own (see update_clinic_settings). Returns
    # { key => FileMan's message } for those refused, or nil when the broker
    # gave no reply.
    def file_settings(ien, values)
      values.each_with_object({}) do |(key, value), failed|
        spec = CLINIC_SETTINGS[key]
        row = { file: spec[:file], field: spec[:field], iens: "#{ien},", value: value }
        filed = in_context { DdrFileman.filer(mode: "EDIT", rows: [ row ], flags: "E") }
        return nil if filed.nil?

        failed[key] = Array(filed[:errors]).join(" ") unless filed[:success]
      end
    end

    def setup_entry?(ien)
      got = in_context { DdrFileman.gets_entry(file: IHS_CLINIC_FILE, iens: "#{ien},", fields: ".01", flags: "I") }
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{IHS_CLINIC_FILE} #{ien}" if got.nil?

      !got[:error]
    end

    # Adds the clinic's CLINIC SETUP PARAMETERS entry (DINUM: its IEN is the
    # clinic's) with the given values. UPDATE^DIE files internal values, which
    # these are (filed_value's codes and numbers). true, FileMan's message, or
    # nil when the broker gave no reply.
    def add_setup_entry(ien, values)
      rows = [ { file: IHS_CLINIC_FILE, field: ".01", iens: "+1,", value: ien.to_s } ]
      values.each do |key, value|
        rows << { file: IHS_CLINIC_FILE, field: CLINIC_SETTINGS[key][:field], iens: "+1,", value: value } unless value == "@"
      end
      added = in_context { DdrFileman.filer(mode: "ADD", rows: rows, iens: { 1 => ien }) }
      return nil if added.nil?

      added[:success] ? true : Array(added[:errors]).join(" ")
    end

    def filer_result(filed)
      return nil if filed.nil?

      filed[:success] ? { success: true } : { success: false, error: Array(filed[:errors]).join(" ") }
    end

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    # The PRIVILEGED USERs of the clinic and of its principal clinic, as DUZs.
    def privileged_users(ien, principal)
      [ ien, principal ].select { |c| c.to_s.match?(/\A[1-9]\d*\z/) }.uniq.flat_map do |clinic|
        list(PRIVILEGED_USER_FILE, "@;.01I", iens: ",#{clinic},").map { |e| e[:pieces].first.to_i }
      end.uniq.sort
    end

    # Every entry DDR LISTER lists for file, read on from each MORE marker
    # until the list ends or stop says an entry is past the end. A page whose
    # reply has no "[Data]" line is a failed read (lister error: true), the
    # same as "[Errors]". "[Data]" with no rows is an empty page. A page resumes
    # from the MORE value alone: LIST^DIC takes the IEN half as FROM("IEN"), a
    # subscript a flat DDR list parameter cannot carry, so this is only for
    # indexes whose values are unique (a holiday's date, an access type's name).
    def list(file, fields, xref: nil, from: nil, stop: nil, iens: nil)
      out = []
      loop do
        page = in_context do
          DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP", max: PAGE, xref: xref, from: from)
        end
        raise Client::RpcError, "DDR LISTER gave no reply for file #{file}" if page.nil?
        raise Client::RpcError, "DDR LISTER refused file #{file}" if page[:error]

        page[:entries].each do |entry|
          return out if stop&.call(entry)

          out << entry
        end
        return out unless page[:more]

        from = page[:more][:value]
      end
    end

    # A date/time as an IENS piece: the FileMan value in canonical form, with
    # no trailing zeros (^SC(clinic,"S",3261110.15) is not ...1500).
    # Files one field of the patient's PATIENT (#44.003) entry on the clinic at
    # that time, found with DDR LISTER, through DDR FILER.
    def file_clinic_entry(hospital_location_id, start_time, patient_dfn, field, value)
      clinic = hospital_location_id.to_s
      raise ArgumentError, "hospital_location_id must be a positive integer" unless clinic.match?(/\A[1-9]\d*\z/)

      at = iens_time(start_time)
      listing = in_context { DdrFileman.lister(file: CLINIC_APPOINTMENT_FILE, iens: ",#{at},#{clinic},", fields: "@;.01I", flags: "IP") }
      return nil if listing.nil?
      return { success: false, error: "DDR LISTER refused ##{CLINIC_APPOINTMENT_FILE} at #{at} on clinic #{clinic}" } if listing[:error]

      entry = listing[:entries].find { |e| e[:pieces].first.to_i == patient_dfn.to_i }
      return { success: false, error: "the clinic holds no appointment for the patient at #{at}" } unless entry

      row = { file: CLINIC_APPOINTMENT_FILE, field: field, iens: "#{entry[:ien]},#{at},#{clinic},", value: value }
      filed = in_context { DdrFileman.filer(mode: "EDIT", rows: [ row ]) }
      return nil if filed.nil?

      filed[:success] ? { success: true } : { success: false, error: Array(filed[:errors]).join(" ") }
    end

    def iens_time(value)
      FilemanDateParser.to_fileman(value).to_s.sub(/(\.\d*?)0+\z/, '\1').delete_suffix(".")
    end

    def fm_date(value)
      FilemanDateParser.to_fileman(value.respond_to?(:to_date) ? value.to_date : value).to_i
    end

    def integer_or_nil(text)
      text.match?(/\A\d+\z/) ? text.to_i : nil
    end

    def date_or_nil(text)
      text.empty? ? nil : FilemanDateParser.parse_date(text)
    end

    def fileman_day(value)
      return unless value.instance_of?(Date)

      FilemanDateParser.to_fileman(value)
    end

    # The name to file, or the :invalid hash. After strip, blank and longer
    # than 30 are the length refusal. "^", a control character, or exactly
    # "@" is the same :invalid shape and sends no RPC. Ordinary text is
    # returned for the FILER call.
    def holiday_name(value)
      return invalid("holiday name must be 1 to 30 characters") unless value.is_a?(String)

      text = value.strip
      return invalid("holiday name must be 1 to 30 characters") if text.empty? || text.length > HOLIDAY_NAME_MAX
      return invalid("holiday name cannot contain ^, a control character, or be @") if refused_free_text?(text)

      text
    end

    def refused_free_text?(text)
      text.include?("^") || text.match?(/[[:cntrl:]]/) || text == "@"
    end

    def filer_outcome(filed)
      return nil if filed.nil?
      return { success: true } if filed[:success]

      { success: false, error: :filer_failed, message: Array(filed[:errors]).join("\n") }
    end

    def invalid(message)
      { success: false, error: :invalid, message: message }
    end
  end
end
