# frozen_string_literal: true

require_relative "../mappings"

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
  # column header; the gateway/mock supplies only the data row here. Live
  # dispatch is blocked on rpms-ops#366 (the YDB releases lack the #8994
  # registry), so these are exercised through MockClient until the backend lands.
  module Scheduling
    extend self

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
      result = DataMapper.scheduling_add_appointment.fetch_one(
        fm(start_time), fm(end_time), patient_dfn.to_s, resource.to_s,
        length_minutes.to_s, note.to_s, access_type.to_s, (chart_request ? "1" : "")
      )
      return nil unless result

      if result[:appointment_id].to_i.positive? && blank?(result[:error])
        { success: true, appointment_id: result[:appointment_id].to_i }
      else
        { success: false, error: result[:error].to_s }
      end
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
    # ERRORID column is "0"/empty on success.
    #
    #   appointment_ien: BSDX APPOINTMENT IEN
    #   checkin_time:    Date/Time or preformatted FileMan date/time
    #   clinic_code:     CLINIC STOP code (optional)
    #   provider:        check-in provider (optional)
    def checkin_appointment(appointment_ien, checkin_time:, clinic_code: nil, provider: nil)
      error_write(:scheduling_checkin_appointment,
                  appointment_ien.to_s, fm(checkin_time), clinic_code.to_s, provider.to_s,
                  zero_ok: true)
    end

    # Mark / clear a no-show — BSDX NOSHOW (NOSHOW^BSDX31 → $$CANCEL^BSDAPI).
    #
    #   no_show: true  => set no-show (default)
    #            false => clear an existing no-show
    #
    # NOTE the routine's ERRORID column is a SUCCESS flag with INVERTED polarity
    # vs the other BSDX writes: 1 == success, 0 == failure (with ERRORTEXT).
    def mark_no_show(appointment_ien, no_show: true)
      result = DataMapper.scheduling_noshow_appointment.fetch_one(
        appointment_ien.to_s, (no_show ? "1" : "0")
      )
      return nil unless result

      if result[:result].to_i == 1
        { success: true }
      else
        { success: false, error: result[:error].to_s }
      end
    end

    # -- reads -----------------------------------------------------------------

    # Search availability blocks — BSDX SEARCH AVAILABILITY (SEARCH^BSDX24).
    #   resources: a resource name or Array of names (joined with "|")
    # Raises ArgumentError when a resource name contains "|" — the wire
    # delimiter — so one name can't smuggle in extra resources.
    # Returns an Array of { resource_name:, date:, access_type:, comment: }.
    def availability(resources:, start_date:, end_date:, access_types: nil, ampm: nil, weekdays: nil)
      names = Array(resources).map(&:to_s)
      names.each do |name|
        raise ArgumentError, "resource name must not contain '|': #{name.inspect}" if name.include?("|")
      end
      list = names.join("|")
      DataMapper.scheduling_availability.fetch_many(
        list, fm(start_date), fm(end_date), access_types.to_s, ampm.to_s, weekdays.to_s
      )
    end

    # All appointments across resources in a date range — BSDX ALL APPOINTMENTS
    # (APBLKALL^BSDX05). Returns an Array of
    # { start_time:, end_time:, patient_dfn: }.
    def all_appointments(start_date:, end_date:)
      DataMapper.scheduling_all_appointments.fetch_many(fm(start_date), fm(end_date))
    end

    # Active clinics from ^SC — BSDX HOSPITAL LOCATION (HOSPLOC^BSDX32).
    def hospital_locations
      DataMapper.scheduling_hospital_location.fetch_many
    end

    # Per-clinic scheduling parameters — BSDX CLINIC SETUP (CLNSET^BSDX32).
    def clinic_setup
      DataMapper.scheduling_clinic_setup.fetch_many
    end

    private

    # For single-ERRORID-column writes (cancel/uncancel/checkin) where an EMPTY
    # error means success ("0" also means success where zero_ok is set, per
    # CHECKIN^BSDX25). fetch_one collapses an empty data row to nil — which we
    # reserve for "unreachable" — so call the RPC directly: an Array response
    # (even [""]) means the broker answered, a "" / nil response means it did
    # not. Header rows (recordset column descriptors) are dropped defensively.
    def error_write(mapping_name, *params, zero_ok: false)
      mapping = DataMapper[mapping_name]
      resp = RpmsRpc.client.call_rpc(mapping.rpc_name, *params)
      return nil if resp.nil? || resp == "" || (resp.is_a?(Array) && resp.empty?)

      row = data_row(resp)
      ok = row.empty? || (zero_ok && row == "0")
      ok ? { success: true } : { success: false, error: row }
    end

    # First non-header data row of a recordset response, as a String.
    def data_row(resp)
      lines = Array(resp).reject { |l| header_row?(l) }
      lines.first.to_s
    end

    # BMX recordset column-header rows look like "T00020ERRORID" / "I00020APPT..."
    # — a type char (I/T/D/F) followed by a 5-digit width. Data rows never match.
    def header_row?(line)
      line.to_s.match?(/\A[ITDF]\d{5}/)
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    # Time/DateTime keep their time of day; Date formats date-only; strings
    # pass through. (Shared helper — the old local `when Date` branch caught
    # DateTime first and dropped the time.)
    def fm(value)
      FilemanDateParser.to_fileman(value)
    end
  end
end
