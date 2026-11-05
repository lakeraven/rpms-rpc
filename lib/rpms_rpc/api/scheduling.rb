# frozen_string_literal: true

require_relative "../mappings"
require_relative "../context_scope"
require_relative "agg"
require_relative "../shape"

module RpmsRpc
  # Symbolic API for RPMS appointment scheduling — the BSDX package (Clinical
  # Scheduling for Windows). Writes delegate server-side to the FileMan-safe
  # scheduling API BSDAPI (updating ^SC and ^BSDXAPPT / file 9002018.4); reads
  # project availability, clinic, and schedule data. Engine code (lakeraven-ehr
  # gateways) calls these methods instead of referencing DataMapper mappings or
  # RPC names directly.
  #
  # Result contract mirrors RpmsRpc::Patient.register:
  #   { success: true, ... }  — the write was accepted
  #   { success: false, error: String } — the broker rejected it (M-side message)
  #   nil — the broker gave no response at all (unreachable), so callers can
  #         distinguish "rejected" from "service unavailable".
  #
  # NB: BSDX RPCs are BMX GLOBAL-ARRAY (recordset) RPCs whose first wire row is a
  # column header; the gateway/mock supplies only the data row here.
  #
  # These are still exercised through MockClient — but NOT because dispatch is
  # unavailable. rpms-ops#366 (the YDB releases lacking the #8994 registry)
  # closed 2026-08-23: ^XWB is force-included in the export and its absence now
  # fails the build. What remains missing is a live-dispatch proof for this RPC
  # set (rpms-rpc#224), which is a different thing from a blocked backend.
  #
  # That distinction matters here: every method below reads a global-array reply
  # through call_rpc. On a CIA broker $C(30) was the frame terminator (until
  # rpms-rpc#241/#244 moved it to \x7f), so each read terminated at the column
  # header — while the seeded tests passed. Same defect as AGG LOOKUP PATIENTS,
  # fixed in #237. Tracked as #254.
  #
  # CiaClient#parse_cia_reply strips the sequence echo and the \x00 ack before
  # Reply.from_wire (cia_client.rb), so call_rpc does not flatten them to
  # spaces. A line that still arrives behind leading spaces, U+FFFD or C0
  # controls is handled defensively. No current client is known to produce
  # that flattened or junk-prefixed shape. recordset_header_row? still returns
  # false for a header behind the prefix. DataMapper#fetch_many and
  # #fetch_many_or_nil on these mappings keep the old contract for direct
  # mapper callers. Only the Scheduling methods changed (#481): the list
  # normaliser strips that prefix before classifying every line, and a header
  # behind it is a header. A header-only recordset, including one whose header
  # carries the prefix, is still a genuine empty result (`[]`). An error row
  # behind the prefix raises with its numeric code, and a line that is blank
  # after the strip counts as empty. A failed read (nil, "", [], a reply with
  # no header row, an error row "-N^…" anywhere, an ERRORID header line
  # anywhere, more than one header line, bytes that are not valid UTF-8, or
  # a reply that is neither Array nor String) raises Client::RpcError. A
  # recordset read with no header row raises ("no recordset header") whether
  # or not the reply is framed. fetch_many_or_raise still accepts an unframed
  # headerless line list whose every non-blank line contains a caret; a
  # non-blank line with no caret raises ("no recordset header"). An ERRORID
  # header line anywhere raises ("ERRORID recordset"); more than one header
  # line otherwise raises ("unexpected second header"). Both paths do. Before
  # any regex, each String chunk is brought to UTF-8: a chunk that is not
  # UTF-8-tagged is duplicated and force-encoded UTF-8, and bytes that are not
  # valid UTF-8 raise ("reply is not valid UTF-8"). A valid binary-tagged
  # reply parses with UTF-8 values. The message names the RPC and, for a
  # "-N^" row, the numeric code ("broker error -1"), or a fixed phrase
  # ("ERRORID recordset", "empty reply", "no recordset header",
  # "unexpected second header", "reply is not valid UTF-8",
  # "unexpected reply type"). Broker text stays out of the message: it can
  # hold a patient name, and sanitize_error does not catch mixed-case names.
  # The failure is never Encoding::CompatibilityError. Hosts must rescue it.
  # Writes are unchanged: an implausible row there is still the symptom of a
  # truncated read, not an empty one.
  #
  # ## Context — this module binds it, callers do not (rpms-rpc#258)
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
  # image every BSDX RPC below is listed in the RPC multiple of ONE file-19
  # option, BSDXRPC ("WINDOWS SCHEDULING PROCEDURE CALLS", 69 entries), and in
  # no other — not the option a CIA sign-on binds (CIAV VUECENTRIC) and not
  # OR CPRS GUI CHART. A user without XUPROGMODE calling them under the
  # sign-on option is denied before any data is returned. So every public
  # method scopes itself to BSDXRPC via ContextScope.scoped (bind, run,
  # restore the caller's option), the way RpmsRpc::Agg does for AGGRPC. A
  # client that cannot scope contexts runs as-is. A programmer-key session
  # bypasses the check either way, so only a non-programmer run is evidence
  # of this bind.
  module Scheduling
    extend self
    extend Shape::Declarable

    # The context option the BSDX RPCs are registered under — see the module
    # doc. Every method here binds it.
    CONTEXT = "BSDXRPC"

    # Book an appointment — BSDX ADD NEW APPOINTMENT (APPADD^BSDX07 → $$MAKE^BSDAPI).
    #
    #   patient_dfn:     patient IEN (^DPT)
    #   resource:        BSDX RESOURCE name (9002018.1 .01)
    #   start_time:/end_time: Date/Time (formatted to FileMan) or preformatted string
    #   length_minutes:  appointment duration
    #   note:            free-text note (optional)
    #   access_type:     access-type IEN for rebooking, or "WALKIN" (optional)
    #   chart_request:   truthy to trigger a chart request (optional)
    #
    # Returns { success: true, appointment_id: Integer } / { success: false, error: } / nil.
    def add_appointment(patient_dfn:, resource:, start_time:, end_time:, length_minutes:,
                        note: nil, access_type: nil, chart_request: false)
      result = in_context do
        DataMapper.scheduling_add_appointment.fetch_one(
          fm(start_time), fm(end_time), patient_dfn.to_s, resource.to_s,
          length_minutes.to_s, note.to_s, access_type.to_s, (chart_request ? "1" : "")
        )
      end
      return nil unless result

      if result[:appointment_id].to_i.positive? && blank?(result[:error])
        { success: true, appointment_id: result[:appointment_id].to_i }
      else
        { success: false, error: result[:error].to_s }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # The note is refused before the write is sent (#472; on a real session the
      # context bind still goes out around it): the module contract is
      # { success: false, error: String }.
      { success: false, error: e.message }
    end

    # Cancel an appointment — BSDX CANCEL APPOINTMENT (APPDEL^BSDX08 → $$CANCEL^BSDAPI).
    #
    #   appointment_ien: BSDX APPOINTMENT IEN (9002018.4)
    #   reason:          CANCELLATION REASON IEN (file 409.2)
    #   type:            "C" clinic-cancelled (default) or "PC" patient-cancelled
    #   note:            optional user note
    def cancel_appointment(appointment_ien, reason:, type: "C", note: nil)
      error_write(:scheduling_cancel_appointment,
                  appointment_ien.to_s, type.to_s, reason.to_s, note.to_s)
    end

    # Undo a clinic cancellation — BSDX UNCANCEL APPT (APPUDEL^BSDX08).
    # (Patient-cancelled appointments cannot be uncancelled server-side.)
    def uncancel_appointment(appointment_ien)
      error_write(:scheduling_uncancel_appointment, appointment_ien.to_s)
    end

    # Check a patient in — BSDX CHECKIN APPOINTMENT (CHECKIN^BSDX25).
    # Success row is "0^"_MESSAGE (BSDX25.m:74); failures are the error text
    # ERR^BSDX25 writes (BSDX25.m:361-365).
    #
    #   appointment_ien: BSDX APPOINTMENT IEN
    #   checkin_time:    Date/Time or preformatted FileMan date/time
    #   clinic_code:     CLINIC STOP code (optional)
    #   provider:        check-in provider (optional)
    #
    # All 8 client formals (BSDX25.m:12 — APTID^CDT^CC^PRV^ROU^VCL^VFM^OG) are
    # sent, the unused tail as empties: the routine passes BSDXVCL/BSDXVFM/
    # BSDXOG to APCHK by value with no $G (BSDX25.m:63), so omitting them
    # <UNDEF>s server-side whenever the resource links a hospital location.
    # Eight, not the pinned build's eleven: the FOIA BSDX25 tag stops at BSDXOG
    # and a longer actual list faults there; the three extra formals are
    # $G-guarded on the pinned build (BSDX25.m:67-69), so eight behave the same.
    def checkin_appointment(appointment_ien, checkin_time:, clinic_code: nil, provider: nil)
      error_write(:scheduling_checkin_appointment,
                  appointment_ien.to_s, fm(checkin_time), clinic_code.to_s, provider.to_s,
                  "", "", "", "",
                  zero_ok: true)
    end

    # Undo a check-in — BSDX CHECKIN APPOINTMENT with "@" as the check-in time,
    # which CHECKIN^BSDX25 takes as "delete check-in": it clears BSDX
    # APPOINTMENT .03 and, through CANCHKIN^BSDX25, the check-in on HOSPITAL
    # LOCATION (#44.003): the time (309) and the user (302) are both cleared on
    # a live 7c3119b build. It does not delete a visit the check-in created.
    # It does not check the appointment was checked in: undoing a check-in
    # that is not there answers success, so a host checks the state first.
    # Returns { success: true } / { success: false, error: } / nil.
    def cancel_checkin(appointment_ien)
      error_write(:scheduling_checkin_appointment,
                  appointment_ien.to_s, "@", "", "", "", "", "", "",
                  zero_ok: true)
    end
    shape :cancel_checkin, resource: "appointments", verb: "POST", path: "/appointments/{appointment_ien}/cancel-checkin"

    # Check a patient out — BSDX CHECKOUT APPOINTMENT (CHECKOUT^BSDX25 →
    # CO^BSDX25A → CO^BSDX25B). It files the check-out time (303), user (304)
    # and when it was entered (306) on HOSPITAL LOCATION (#44.003), BSDX
    # APPOINTMENT .14, and the visit's CHECK OUT DATE&TIME (.18) when there is
    # a visit.
    #
    #   appointment_ien:  BSDX APPOINTMENT IEN
    #   patient_dfn:      the appointment's patient (the routine takes it apart
    #                     from the appointment)
    #   appointment_time: the appointment's start (Date/Time or FileMan)
    #   checkout_time:    when the patient left (Date/Time or FileMan)
    #
    # The success row is "0"; RPMS refuses, with the reason as the row, a
    # check-out in the future ("Check Out time cannot be in the future."), one
    # not at least a minute after the check-in, and an appointment not checked
    # in ("BSDX25B: Patient not checked in"). The fifth formal, VPRV, re-points
    # a V PROVIDER entry and is sent empty.
    # Returns { success: true } / { success: false, error: } / nil.
    def checkout_appointment(appointment_ien, patient_dfn:, appointment_time:, checkout_time:)
      error_write(:scheduling_checkout_appointment,
                  patient_dfn.to_s, fm(appointment_time), fm(checkout_time), appointment_ien.to_s, "",
                  zero_ok: true)
    end
    shape :checkout_appointment, resource: "appointments", verb: "POST", path: "/appointments/checkout-appointments/{appointment_ien}/patients/{patient_dfn}"

    # Undo a check-out — BSDX CANCEL CHECKOUT APPT (CANCKOUT^BSDX25). It clears
    # the check-out on HOSPITAL LOCATION (#44.003: 303, 304, 306), BSDX
    # APPOINTMENT .14 and the visit's .18, and puts the outpatient encounter
    # back to checked in. An appointment not checked out is refused
    # ("Appointment is not Checked Out."). The success row is "0".
    # Returns { success: true } / { success: false, error: } / nil.
    def cancel_checkout(appointment_ien)
      error_write(:scheduling_cancel_checkout, appointment_ien.to_s, zero_ok: true)
    end
    shape :cancel_checkout, resource: "appointments", verb: "POST", path: "/appointments/{appointment_ien}/cancel-checkout"

    # Mark / clear a no-show — BSDX NOSHOW (NOSHOW^BSDX31 → $$CANCEL^BSDAPI).
    #
    #   no_show: true  => set no-show (default)
    #            false => clear an existing no-show
    #
    # NOTE the routine's ERRORID column is a SUCCESS flag with INVERTED polarity
    # vs the other BSDX writes: 1 == success, 0 == failure (with ERRORTEXT).
    def mark_no_show(appointment_ien, no_show: true)
      result = in_context do
        DataMapper.scheduling_noshow_appointment.fetch_one(
          appointment_ien.to_s, (no_show ? "1" : "0")
        )
      end
      return nil unless result

      if result[:result].to_i == 1
        { success: true }
      else
        { success: false, error: result[:error].to_s }
      end
    end

    # -- reads -----------------------------------------------------------------
    #
    # A failed list read raises Client::RpcError (#481). These used to return
    # [] on failure (resources, appointments and slot_schedule returned nil
    # when the broker gave no response). A header-only recordset, including a
    # header behind leading spaces, U+FFFD or C0 controls, is still []. That
    # flattened shape is handled defensively; no current client is known to
    # produce it. fetch_many_or_raise still accepts an unframed headerless
    # line list whose every non-blank line contains a caret; a non-blank line
    # with no caret raises ("no recordset header"). An ERRORID header line
    # anywhere raises ("ERRORID recordset"); more than one header line
    # otherwise raises ("unexpected second header"). Both paths do. Before any
    # regex, each String chunk is brought to UTF-8: a chunk that is not
    # UTF-8-tagged is duplicated and force-encoded UTF-8, and bytes that are
    # not valid UTF-8 raise ("reply is not valid UTF-8"). A valid binary-tagged
    # reply parses with UTF-8 values. The message names the RPC and, for a
    # "-N^" row, the numeric code ("broker error -1"), or a fixed phrase
    # ("ERRORID recordset", "empty reply", "no recordset header",
    # "unexpected second header", "reply is not valid UTF-8",
    # "unexpected reply type"). Broker text stays out of the message: it can
    # hold a patient name, and sanitize_error does not catch mixed-case names.
    # The failure is never Encoding::CompatibilityError. Hosts must rescue it.

    # Search availability blocks — BSDX SEARCH AVAILABILITY (SEARCH^BSDX24).
    #   resources: a resource name or Array of names (joined with "|")
    # Raises ArgumentError when a resource name contains "|" — the wire
    # delimiter — so one name can't smuggle in extra resources.
    # Returns an Array of { resource_name:, date:, access_type:, comment: }.
    # :date is a Date parsed from the routine's EXTERNAL-format output
    # (DD^%DT — BSDX24.m:116-117); :comment is always nil (the routine never
    # populates it — BSDX24.m:123-124).
    def availability(resources:, start_date:, end_date:, access_types: nil, ampm: nil, weekdays: nil)
      names = Array(resources).map(&:to_s)
      names.each do |name|
        raise ArgumentError, "resource name must not contain '|': #{name.inspect}" if name.include?("|")
      end
      list = names.join("|")
      in_context do
        DataMapper.scheduling_availability.fetch_many_or_raise(
          list, fm(start_date), fm(end_date), access_types.to_s, ampm.to_s, weekdays.to_s
        )
      end
    end

    # All appointments across resources in a date range — BSDX ALL APPOINTMENTS
    # (APBLKALL^BSDX05). Returns an Array of
    # { start_time:, end_time:, patient_dfn:, resource_name: }.
    # :start_time/:end_time are Times parsed from the routine's EXTERNAL-format
    # output (X ^DD("DD") with "@" translated to a space — BSDX05.m:100-101);
    # :resource_name is the 4th column GATHER^BSDX05 appends (BSDX05.m:65,76).
    def all_appointments(start_date:, end_date:)
      in_context { DataMapper.scheduling_all_appointments.fetch_many_or_raise(fm(start_date), fm(end_date)) }
    end

    # Active clinics from ^SC — BSDX HOSPITAL LOCATION (HOSPLOC^BSDX32).
    def hospital_locations
      in_context { DataMapper.scheduling_hospital_location.fetch_many_or_raise }
    end

    # A resource's appointments between two dates — BSDX CREATE APPT SCHEDULE
    # (CRSCH^BSDX02), the appointment list the scheduling client draws. Unlike
    # all_appointments it carries each appointment's id (what cancel, check-in
    # and no-show take) and its state. Cancelled appointments are included and
    # marked; walk-ins are included. The note may hold CR/LF, so the reply is
    # read as a recordset. It only reads, but the RPC is named CREATE, so it is
    # classed and shaped as a write (never retried), like slot_schedule.
    # Returns [{ id:, start_time:, end_time:, checkin_time:, patient_dfn:,
    #   patient_name:, resource:, no_show:, hrn:, access_type_id:, walk_in:,
    #   checkout_time:, cancelled:, note: }]. A failed read raises
    # Client::RpcError; a header-only reply is [].
    def appointments(resource:, start_date:, end_date:)
      name = resource.to_s
      raise ArgumentError, "resource name must not contain '|': #{name.inspect}" if name.include?("|")

      rows = in_context { recordset("BSDX CREATE APPT SCHEDULE", name, "#{fm(start_date)}.0001", "#{fm(end_date)}.2359", "") }
      rows&.map do |r|
        { id: r[:appointmentid].to_i, start_time: external_time(r[:start_time]), end_time: external_time(r[:end_time]),
          checkin_time: external_time(r[:checkin]), patient_dfn: r[:patientid].to_i, patient_name: r[:patientname],
          resource: r[:resourcename], no_show: r[:noshow].to_s == "1", hrn: blank_to_nil(r[:hrn]),
          access_type_id: r[:accesstypeid].to_i, walk_in: r[:walkin].to_s == "1",
          checkout_time: external_time(r[:checkout]), cancelled: r[:cancelled].to_s == "1", note: blank_to_nil(r[:note]) }
      end
    end
    shape :appointments, resource: "appointments", verb: "POST", path: "/appointments"

    # One patient's appointments across clinics — BSDX PATIENT APPT DISPLAY
    # (PADISP^BSDX27), the scheduling client's patient appointment list. Returns
    # [{ start_time:, clinic:, resource_id:, type:, status:, made_by:, made_at:, note: }].
    # :type is SCHED or WALK-IN ($$APPTYP^BSDU2); :status is scheduled, checked
    # in, checked out, no-show or cancelled (STATUS^BSDX27). A live capture
    # contradicted the earlier note that the routine leaves out a cancelled
    # BSDX appointment, so do not rely on a cancelled row being absent. Each row also carries the patient's
    # name, date of birth, HRN, address and phone; they are not returned.
    # ERR^BSDX27's row of empty pieces raises Client::RpcError.
    def patient_appointments(dfn)
      rows = in_context { recordset("BSDX PATIENT APPT DISPLAY", dfn.to_s) }
      rows.map do |r|
        raise Client::RpcError, "BSDX PATIENT APPT DISPLAY: the routine answered its error row" if r.values.all? { |v| v.to_s.empty? }

        type, state = r[:typestatus].to_s.split(" - ", 2)
        { start_time: external_time(r[:apptdate]), clinic: r[:clinic], resource_id: r[:resourceid].to_i,
          type: type, status: PATIENT_APPOINTMENT_STATUS.fetch(state.to_s, state.to_s.downcase),
          made_by: blank_to_nil(r[:appt_made_by]), made_at: external_time(r[:date_appt_made]), note: blank_to_nil(r[:note]) }
      end
    end
    shape :patient_appointments, resource: "appointments", verb: "GET", path: "/patients/{dfn}/appointments"

    PATIENT_APPOINTMENT_STATUS = {
      "" => "scheduled", "CHECKED IN" => "checked in", "CHECKED OUT" => "checked out",
      "NO SHOW" => "no-show", "CANCELLED" => "cancelled"
    }.freeze

    # The scheduling resources and this user's rights on each — BSDX RESOURCES
    # (RESUSR^BSDX01, for DUZ). A resource is what an appointment is booked on
    # (add_appointment's resource:), linked to its clinic by
    # hospital_location_id. time_scale is its slot length in minutes. The rights
    # come from BSDX RESOURCE USER (#9002018.15); BSDXZMGR or XUPROGMODE grants
    # all four (BSDX01.m). The letter columns are left out: their word-processing
    # text carries CR/LF, so the reply is read as a recordset split on $C(30)
    # only, never by line.
    # Returns [{ id:, name:, inactive:, time_scale:, hospital_location_id:, view:,
    #   overbook:, modify_schedule:, modify_appointments: }]. A failed read raises
    # Client::RpcError; a header-only reply is [].
    def resources
      rows = in_context { recordset("BSDX RESOURCES", "") }
      rows&.map do |r|
        { id: r[:resourceid].to_i, name: r[:resource_name], inactive: r[:inactive].to_s == "1",
          time_scale: r[:timescale].to_i, hospital_location_id: r[:hospital_location_id].to_i,
          view: r[:view].to_s == "1", overbook: r[:overbook].to_s == "1",
          modify_schedule: r[:modify_schedule].to_s == "1", modify_appointments: r[:modify_appointments].to_s == "1" }
      end
    end
    shape :resources, resource: "appointments", verb: "GET", path: "/appointments/resources"

    # A resource's access blocks between two dates, with their slots — BSDX
    # CREATE ASGND SLOT SCHED (CASSCH^BSDX04), what the scheduling client draws
    # its calendar from. slots is how many appointments the block holds at a
    # time; BSDX ADD NEW APPOINTMENT does not enforce it (a fifth booking into a
    # four-slot block files), so a caller that books must. Blocks with 0 slots
    # pad the day before and after the access blocks.
    # Returns [{ start_time:, end_time:, slots:, resource:, access_type_id:,
    #   note:, availability_id: }]. A failed read raises Client::RpcError; a
    # header-only reply is [].
    def slot_schedule(resource:, start_date:, end_date:)
      name = resource.to_s
      raise ArgumentError, "resource name must not contain '|': #{name.inspect}" if name.include?("|")

      rows = in_context { recordset("BSDX CREATE ASGND SLOT SCHED", name, "#{fm(start_date)}.0001", "#{fm(end_date)}.2359", "", "") }
      rows&.map do |r|
        { start_time: FilemanDateParser.parse_external_datetime(r[:start_time]),
          end_time: FilemanDateParser.parse_external_datetime(r[:end_time]),
          slots: r[:slots].to_i, resource: r[:resource], access_type_id: r[:access_type].to_i,
          note: (r[:note].to_s.empty? ? nil : r[:note]), availability_id: r[:availabilityid].to_i }
      end
    end
    # It only reads (CASSCH fills ^BSDXTMP), but the RPC is named CREATE, so it is
    # classed and shaped as a write: never retried, and never offered as a GET.
    shape :slot_schedule, resource: "appointments", verb: "POST", path: "/appointments/slot-schedule"

    # Add one access block to a clinic's resource — BSDX ADD NEW AVAILABILITY
    # (AVADD^BSDX12), what Windows Scheduling sends for each block it files
    # (rpms-ux S-SCH-14). It parses the times with ^%DT as BSDX ADD NEW
    # APPOINTMENT does, files BSDX ACCESS BLOCK (#9002018.3) .01 resource, .02
    # start, .03 end, .04 slots, .05 access type, and the note as its WP field.
    #
    #   resource:       BSDX RESOURCE name (9002018.1 .01)
    #   start_time:/end_time: Time/DateTime (formatted to FileMan) or preformatted
    #   slots:          appointments each slot of the block takes, 1 or more
    #   access_type_id: BSDX ACCESS TYPE IEN (9002018.35)
    #
    # AVADD swaps a start after the end instead of refusing it, so an end not
    # after the start is refused here before anything is sent (ArgumentError),
    # as is a slot count under 1. The reply is "AVAILABILITYID^-1" on success
    # and "0^<134234112+70>" when RPMS refuses (ERR^BSDX12: a bad date, access
    # type or resource name).
    # Returns { success: true, availability_id: Integer } / { success: false, error: } / nil.
    def add_availability(resource:, start_time:, end_time:, slots:, access_type_id:, note: nil)
      raise ArgumentError, "end_time must be after start_time" unless end_time > start_time
      raise ArgumentError, "slots must be 1 or more: #{slots.inspect}" unless slots.to_i >= 1

      resp = in_context do
        RpmsRpc.client.call_rpc("BSDX ADD NEW AVAILABILITY", fm(start_time), fm(end_time),
                                access_type_id.to_s, resource.to_s, slots.to_i.to_s, note.to_s)
      end
      return nil if unanswered?(resp)

      row = data_row(resp)
      id, code = row.split("^", -1)
      return { success: true, availability_id: id.to_i } if id.to_i.positive? && code == "-1"

      { success: false, error: row }
    rescue RpmsRpc::Client::FrameTooLongError => e
      { success: false, error: e.message }
    end
    shape :add_availability, resource: "appointments", verb: "POST", path: "/appointments/availability"

    # Delete every access block of a resource that starts between two dates,
    # inclusive — BSDX CANCEL AV BY DATE (AVDELDT^BSDX13).
    #
    #   resource_id: BSDX RESOURCE IEN (9002018.1)
    #   start_date:/end_date: Date (formatted to FileMan) or preformatted
    #
    # It does NOT check for appointments: APTINBLK is commented out as not
    # called in the current version (BSDX13.m), so a booked appointment stays
    # on a day whose blocks are gone. A caller that must keep the bookings
    # covered (rpms-ux S-SCH-14.5) checks them first. The reply is "-1^" on
    # success and "0^<text>" for a bad date or resource.
    # Returns { success: true } / { success: false, error: } / nil.
    def cancel_availability_by_date(resource_id:, start_date:, end_date:)
      resp = in_context do
        RpmsRpc.client.call_rpc("BSDX CANCEL AV BY DATE", resource_id.to_s, fm(start_date), fm(end_date))
      end
      return nil if unanswered?(resp)

      row = data_row(resp)
      row.split("^", -1).first == "-1" ? { success: true } : { success: false, error: row }
    end
    shape :cancel_availability_by_date, resource: "appointments", verb: "POST", path: "/appointments/cancel-availability-by-date"

    # Whether one more overbook may be booked on the resource that day, under
    # the clinic's OVERBOOKS/DAY MAXIMUM (#44 field 1918) — BSDX OVERBOOK
    # (APPOVB^BSDX07A), what the Windows scheduler asks before it offers an
    # overbook. The routine counts, for the resource, the appointments past
    # each access block's slots that day (CNTOB^BSDX07A) and answers YES while
    # that count is under the maximum, NO when it is not. A clinic with no
    # maximum answers NO.
    #
    #   hospital_location_id: the resource's clinic (#44 IEN)
    #   start_time:           the time asked for (only its date is counted)
    #   resource_id:          BSDX RESOURCE IEN (9002018.1)
    #
    # Returns true or false. Its error rows (an invalid clinic, resource or
    # date) raise Client::RpcError, as a failed read does.
    def overbook_allowed(hospital_location_id:, start_time:, resource_id:)
      rows = in_context { recordset("BSDX OVERBOOK", hospital_location_id.to_s, fm(start_time), resource_id.to_s) }
      answer = rows.first&.dig(:overbook).to_s
      raise Client::RpcError, "BSDX OVERBOOK: no YES or NO in the reply" unless %w[YES NO].include?(answer)

      answer == "YES"
    end
    shape :overbook_allowed, resource: "appointments", verb: "POST", path: "/appointments/overbook-allowed"

    # Change an appointment's note and length — BSDX EDIT APPOINTMENT
    # (EDITAPT^BSDX26), what the Windows scheduler sends from its appointment
    # dialog (rpms-ux S-SCH-09).
    #
    #   appointment_ien: BSDX APPOINTMENT IEN (9002018.4)
    #   note:            the whole note. The routine replaces the BSDX
    #                    APPOINTMENT note (field 1) with it, so an unchanged
    #                    note must be sent again; blank clears it.
    #   length_minutes:  the new length, or nil to keep it. The routine files
    #                    LENGTH OF APP'T (#44.003 field 1) on the clinic entry
    #                    whose length is the old one, and the BSDX end time.
    #
    # The routine does not touch the clinic's own copy of the note, OTHER
    # (#44.003 field 3); SchedulingSetup.set_clinic_note does.
    # Returns { success: true } ("-1" row), { success: false, error: } (the
    # routine's error row), or nil when the broker gives no reply.
    def edit_appointment(appointment_ien, note:, length_minutes: nil)
      resp = in_context do
        RpmsRpc.client.call_rpc("BSDX EDIT APPOINTMENT", appointment_ien.to_s, note.to_s, length_minutes.to_s)
      end
      return nil if resp.nil? || resp == "" || (resp.is_a?(Array) && resp.empty?)

      row = data_row(resp)
      row.strip == "-1" ? { success: true } : { success: false, error: row }
    rescue RpmsRpc::Client::FrameTooLongError => e
      { success: false, error: e.message }
    end
    shape :edit_appointment, resource: "appointments", verb: "POST", path: "/appointments/edit-appointments/{appointment_ien}"

    # Whether the clinic allows variable appointment lengths — BSDX CLINIC VAR
    # APPT (VAL^BSDX37): VARIABLE APPOINTMENT LENGTH (#44 field 1913) is YES.
    # Only such a clinic's appointments may change length (rpms-ux S-SCH-09.4).
    # An invalid clinic's error row raises Client::RpcError.
    def variable_length?(hospital_location_id)
      rows = in_context { recordset("BSDX CLINIC VAR APPT", hospital_location_id.to_s) }
      flag = rows.first&.dig(:var_appt_flag).to_s.strip
      raise Client::RpcError, "BSDX CLINIC VAR APPT: no flag in the reply" unless %w[0 1].include?(flag)

      flag == "1"
    end
    shape :variable_length?, resource: "appointments", verb: "POST", path: "/appointments/variable-length"

    # Per-clinic scheduling parameters — BSDX CLINIC SETUP (CLNSET^BSDX32).
    def clinic_setup
      in_context { DataMapper.scheduling_clinic_setup.fetch_many_or_raise }
    end

    private

    # Bind BSDXRPC for the duration of the block and restore the caller's
    # option afterward (a no-op round-trip-wise when BSDXRPC is already
    # bound). Every wire-reaching path above goes through here.
    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    # For ERRORID-led writes (cancel/uncancel/checkin) where an EMPTY ERRORID
    # piece means success ("0" also means success where zero_ok is set, per
    # CHECKIN^BSDX25). fetch_one collapses an empty data row to nil — which we
    # reserve for "unreachable" — so call the RPC directly: an Array response
    # (even [""]) means the broker answered, a "" / nil response means it did
    # not. Success is judged on the FIRST caret piece: the live check-in
    # success row is "0^"_MESSAGE (BSDX25.m:74), not a bare "0". Failure rows
    # carry the error text in the first piece (ERR^BSDX25: BSDX25.m:361-365).
    def error_write(mapping_name, *params, zero_ok: false)
      mapping = DataMapper[mapping_name]
      resp = in_context { RpmsRpc.client.call_rpc(mapping.rpc_name, *params) }
      return nil if resp.nil? || resp == "" || (resp.is_a?(Array) && resp.empty?)

      row = data_row(resp)
      error_id = row.split("^", -1).first.to_s
      ok = error_id.empty? || (zero_ok && error_id == "0")
      ok ? { success: true } : { success: false, error: row }
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A note or reason the wire would mis-frame is refused before the write is
      # sent (#472; on a real session the context bind still goes out around
      # it): the module contract is { success: false, error: String }.
      { success: false, error: e.message }
    end

    # A BMX recordset reply's rows as header-named hashes. Read whole, so a
    # field holding CR/LF stays inside its row (split_newlines: false).
    # DataMapper.read_bsdx_list! returns the classified lines: the header with
    # leading junk stripped, then the data rows in their original bytes, as
    # UTF-8 (a chunk that was not UTF-8-tagged is duplicated and force-encoded
    # before it is read). Those lines are parsed here, not the raw reply, so a
    # flattened header maps the same columns as an unflattened one. A failed
    # read raises Client::RpcError; a header-only reply is []. A reply with no
    # header row raises ("no recordset header") whether or not it is framed.
    # An ERRORID header line anywhere raises ("ERRORID recordset"); more than
    # one header line otherwise raises ("unexpected second header"). Invalid
    # UTF-8 raises ("reply is not valid UTF-8"), never Encoding::CompatibilityError.
    def recordset(rpc_name, *params)
      client = RpmsRpc.client
      raw = if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(rpc_name, *params)
      else
        client.call_rpc(rpc_name, *params)
      end
      lines = DataMapper.read_bsdx_list!(raw, rpc_name, split_newlines: false)
      return [] if lines == :empty

      names = recordset_column_names(lines.first)
      lines.drop(1).map { |row| recordset_record(names, row) }
    end

    # Agg.parse_reply's column rule, on the classifier's header line:
    # "<type><5-digit width><NAME>" becomes the downcased name.
    def recordset_column_names(header)
      header.to_s.split("^", -1).map do |piece|
        matched = piece.match(/\A[A-Z]\d{5}(.*)\z/m)
        (matched ? matched[1] : piece).downcase.to_sym
      end
    end

    def recordset_record(names, row)
      pieces = row.to_s.split("^", -1)
      names.each_with_index.to_h { |name, index| [ name, pieces[index] ] }
    end

    def external_time(text)
      FilemanDateParser.parse_external_datetime(text) unless text.to_s.strip.empty?
    end

    def blank_to_nil(value)
      value.to_s.empty? ? nil : value
    end

    # First non-header data row of a recordset response, as a String with the
    # $C(30)/$C(31) record separators stripped (shared recordset framing
    # rules live in DataMapper — see RECORDSET_SEPARATORS there). An empty row
    # is kept: for ERRORID-only writes it means success.
    def data_row(resp)
      Array(resp).map { |l| DataMapper.strip_recordset_separators(l) }
                 .reject { |l| DataMapper.recordset_header_row?(l) }
                 .first.to_s
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    # No reply at all: the broker did not answer (the nil of the module contract).
    def unanswered?(resp)
      resp.nil? || resp == "" || (resp.is_a?(Array) && resp.empty?)
    end

    # Time/DateTime keep their time of day; Date formats date-only; strings
    # pass through. (Shared helper — the old local `when Date` branch caught
    # DateTime first and dropped the time.)
    def fm(value)
      FilemanDateParser.to_fileman(value)
    end
  end
end
