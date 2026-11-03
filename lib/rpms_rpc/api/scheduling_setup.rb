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

    # How many entries one DDR LISTER call asks for; a longer list is read on
    # from the MORE marker.
    PAGE = 100

    # HOLIDAY (#40.5) field 2 NAME. The unit contract refuses a longer name
    # before any RPC; FileMan would refuse it on the write.
    HOLIDAY_NAME_MAX = 30

    # Every BSDX ACCESS TYPE (#9002018.35) with its .01 ACCESS TYPE NAME, .02
    # INACTIVE and .08 PREVENT ACCESS. A block whose access type prevents access
    # takes no appointment (rpms-ux S-SCH-04.2). An unset flag reads as false.
    # Returns [{ id:, name:, inactive:, prevent_access: }], by name. A failed
    # read raises Client::RpcError.
    def access_types
      list(ACCESS_TYPE_FILE, "@;.01;.02I;.08I").map do |entry|
        name, inactive, prevent = entry[:pieces]
        { id: entry[:ien].to_i, name: name, inactive: inactive == "1", prevent_access: prevent == "1" }
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
      clinic = hospital_location_id.to_s
      raise ArgumentError, "hospital_location_id must be a positive integer" unless clinic.match?(/\A[1-9]\d*\z/)

      at = iens_time(start_time)
      listing = in_context { DdrFileman.lister(file: CLINIC_APPOINTMENT_FILE, iens: ",#{at},#{clinic},", fields: "@;.01I;9I", flags: "IP") }
      return nil if listing.nil?
      return { success: false, error: "DDR LISTER refused ##{CLINIC_APPOINTMENT_FILE} at #{at} on clinic #{clinic}" } if listing[:error]

      entry = listing[:entries].find { |e| e[:pieces].first.to_i == patient_dfn.to_i }
      return { success: false, error: "the clinic holds no appointment for the patient at #{at}" } unless entry
      return { success: true } if entry[:pieces][1] == "O"

      row = { file: CLINIC_APPOINTMENT_FILE, field: "9", iens: "#{entry[:ien]},#{at},#{clinic},", value: "O" }
      filed = in_context { DdrFileman.filer(mode: "EDIT", rows: [ row ]) }
      return nil if filed.nil?

      filed[:success] ? { success: true } : { success: false, error: Array(filed[:errors]).join(" ") }
    end
    shape :mark_overbook, resource: "appointments", verb: "POST", path: "/patients/{patient_dfn}/appointments/mark-overbook"
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

    private

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
