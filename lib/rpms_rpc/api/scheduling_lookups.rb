# frozen_string_literal: true

require_relative "scheduling"

module RpmsRpc
  # The Windows scheduling client's lookups beside the calendar: who
  # schedules, the resource groups a user sees, the letters each resource
  # names, a patient's no-show standing and appointment history, the letter
  # and cancellation lists for resources and a date range, and what an
  # appointment or access block would overlap (BSDX, under BSDXRPC). Reads only.
  #
  # Each is a BMX recordset read through Scheduling's own recordset reader, so
  # a failed read raises Client::RpcError and a header-only reply is [].
  module Scheduling
    # BSDX SCHEDULE USER (SCHUSR^BSDX17): the users who hold BSDXZMENU,
    # BSDXZMGR or XUPROGMODE, as { id:, name: }.
    def schedule_users
      rows = in_context { recordset("BSDX SCHEDULE USER") }
      rows.map { |r| { id: r[:userid].to_i, name: r[:username] } }
    end
    shape :schedule_users, resource: "appointments", verb: "GET", path: "/appointments/schedule-users"

    # BSDX SCHEDULING USER INFO (SUINFO^BSDX01): true when $$APSEC^BSDX01
    # finds BSDXZMGR, the scheduling manager key (or XUPROGMODE), for the user.
    # `duz` defaults to the signed-on user.
    def scheduling_manager?(duz: RpmsRpc.client.duz)
      rows = in_context { recordset("BSDX SCHEDULING USER INFO", duz.to_s) }
      rows.first&.dig(:manager).to_s == "YES"
    end
    shape :scheduling_manager?, resource: "appointments", verb: "GET", path: "/appointments/scheduling-manager"

    # BSDX RESOURCE GROUPS BY USER (DEPUSR^BSDX01; BSDX DEPARTMENTS BY USER
    # is the same entry): the resource groups holding a resource the user
    # may see, as { id:, name: }.
    def user_resource_groups(duz: RpmsRpc.client.duz)
      rows = in_context { recordset("BSDX RESOURCE GROUPS BY USER", duz.to_s) }
      rows.map { |r| { id: r[:resource_groupid].to_i, name: r[:resource_group] } }
    end
    shape :user_resource_groups, resource: "appointments", verb: "GET", path: "/appointments/user-resource-groups"

    # BSDX GROUP RESOURCE (DEPRES^BSDX01; BSDX DEPARTMENT RESOURCE is the
    # same entry): each group's resources the user may see, one row per
    # group and resource.
    def user_resource_group_members(duz: RpmsRpc.client.duz)
      rows = in_context { recordset("BSDX GROUP RESOURCE", duz.to_s) }
      rows.map do |r|
        { group_id: r[:resource_groupid].to_i, group: r[:resource_group], item_id: r[:resource_group_itemid].to_i,
          resource: r[:resource_name], resource_id: r[:resourceid].to_i }
      end
    end
    shape :user_resource_group_members, resource: "appointments", verb: "GET", path: "/appointments/user-resource-group-members"

    # BSDX RESOURCE LETTERS (RSRCLTR^BSDX35): the letter, no-show letter and
    # clinic-cancellation letter text each resource names, for the resource
    # IDs given. Blank text is nil.
    def resource_letters(resource_ids)
      rows = in_context { recordset("BSDX RESOURCE LETTERS", "#{Array(resource_ids).join('|')}|") }
      rows.map do |r|
        { id: r[:resourceid].to_i, name: r[:resource_name], letter: blank_to_nil(r[:letter_text]),
          no_show_letter: blank_to_nil(r[:no_show_letter]), cancellation_letter: blank_to_nil(r[:clinic_cancellation_letter]) }
      end
    end
    shape :resource_letters, resource: "appointments", verb: "GET", path: "/appointments/resource-letters"

    # BSDX NOSHOW COUNT (NS^BSDX37): a patient's no-shows at a clinic (#44
    # IEN) against the clinic's allowance. nil when the routine answers its
    # error row.
    def no_show_count(dfn, clinic_ien)
      row = in_context { recordset("BSDX NOSHOW COUNT", dfn.to_s, clinic_ien.to_s) }.first
      return nil if row.nil? || row[:patient_ien].to_s !~ /\A\d+\z/

      { patient_dfn: row[:patient_ien].to_i, clinic_ien: row[:clinic_ien].to_i, too_many: row[:too_many] == "1",
        allowed: row[:allowed_no_shows].to_i, total: row[:total_no_shows].to_i }
    end
    shape :no_show_count, resource: "appointments", verb: "GET", path: "/patients/{dfn}/appointments/clinics/{clinic_ien}/no-show-count"

    # BSDXPatientLookupRS (PTLOOKRS^BSDX28): the scheduling client's patient
    # lookup by name, HRN or SSN, at most `max` rows, as { dfn:, name:, hrn:, dob: }.
    # The SSN column is not returned.
    def patient_lookup(text, max: 10)
      rows = in_context { recordset("BSDXPatientLookupRS", text.to_s, max.to_s) }
      rows.map { |r| { dfn: r[:ien].to_i, name: r[:name], hrn: blank_to_nil(r[:hrn]), dob: external_time(r[:dob])&.to_date } }
    end
    shape :patient_lookup, resource: "appointments", verb: "GET", path: "/appointments/patient-lookup"

    # BSDX APPT EVENT LOG (DAP^BSDX38): every appointment of a patient with
    # who made, checked in, checked out or cancelled it, and when. Times stay
    # the external text the routine sends; blank is nil.
    def appointment_events(dfn)
      rows = in_context { recordset("BSDX APPT EVENT LOG", dfn.to_s) }
      rows.map { |r| r.transform_values { |v| blank_to_nil(v) } }
    end
    shape :appointment_events, resource: "appointments", verb: "GET", path: "/patients/{dfn}/appointments/events"

    # BSDX CLINIC LETTERS (CLDISP^BSDX27): the appointments on the resources
    # (BSDX RESOURCE IDs) between two dates the reminder letters go to, with
    # the patient's mailing address. `walk_in: true` returns only walk-ins.
    def appointment_letter_list(resource_ids, start_date:, end_date:, walk_in: false)
      letter_rows(in_context do
        recordset("BSDX CLINIC LETTERS", list(resource_ids), external_date(start_date), external_date(end_date), walk_in ? "1" : "0")
      end)
    end
    shape :appointment_letter_list, resource: "appointments", verb: "GET", path: "/appointments/letter-list"

    # BSDX CANCEL CLINIC LIST (CANCLIN^BSDX34): the clinic-cancelled
    # appointments on the resources in the range the cancellation letters go to.
    def cancellation_letter_list(resource_ids, start_date:, end_date:)
      letter_rows(in_context do
        recordset("BSDX CANCEL CLINIC LIST", list(resource_ids), external_date(start_date), external_date(end_date))
      end)
    end
    shape :cancellation_letter_list, resource: "appointments", verb: "GET", path: "/appointments/cancellation-letter-list"

    # BSDX APPT BLOCKS OVERLAP (APBLKOV^BSDX05): the appointments on a
    # resource (by name) that overlap start..end, as { start_time:, end_time:, patient_dfn: }.
    def appointment_overlaps(resource:, start_time:, end_time:, walk_in: false)
      rows = in_context do
        recordset("BSDX APPT BLOCKS OVERLAP", overlap_time(start_time), overlap_time(end_time), resource.to_s, walk_in ? "1" : "0")
      end
      rows.map { |r| { start_time: external_time(r[:start_time]), end_time: external_time(r[:end_time]), patient_dfn: r[:pat_id].to_i } }
    end
    shape :appointment_overlaps, resource: "appointments", verb: "GET", path: "/appointments/overlaps"

    # BSDX TYPE BLOCKS OVERLAP (TPBLKOV^BSDX06): the access blocks on a
    # resource that overlap start..end.
    def access_block_overlaps(resource:, start_time:, end_time:)
      rows = in_context { recordset("BSDX TYPE BLOCKS OVERLAP", overlap_time(start_time), overlap_time(end_time), resource.to_s) }
      rows.map do |r|
        { start_time: external_time(r[:starttime]), end_time: external_time(r[:endtime]), access_type_id: r[:appointmenttypeid].to_i,
          availability_id: r[:availabilityid].to_i, resource: r[:resourcename] }
      end
    end
    shape :access_block_overlaps, resource: "appointments", verb: "GET", path: "/appointments/access-block-overlaps"

    # BSDX HS PWH TYPES (PWH^BSDX39): the patient wellness handout types the
    # client prints with a health summary, as { id:, name: }.
    def wellness_handout_types
      rows = in_context { recordset("BSDX HS PWH TYPES") }
      rows.map { |r| { id: r[:pwh_type_ien].to_i, name: r[:pwh_type_name] } }
    end
    shape :wellness_handout_types, resource: "appointments", verb: "GET", path: "/appointments/wellness-handout-types"

    private

    def list(iens) = "#{Array(iens).join('|')}|"

    # CLDISP and CANCLIN read their dates with ^%DT ("X"): external, M/D/YYYY.
    def external_date(value) = value.respond_to?(:strftime) ? value.strftime("%-m/%-d/%Y") : value.to_s

    # The BSDX overlap entries read their times with ^%DT ("T"): M/D/YYYY@HH:MM.
    def overlap_time(value)
      return value.to_s unless value.respond_to?(:strftime)

      value.strftime("%-m/%-d/%Y@%H:%M")
    end

    def letter_rows(rows)
      rows.map do |r|
        { name: r[:name], dob: external_time(r[:dob])&.to_date, sex: blank_to_nil(r[:sex]), hrn: blank_to_nil(r[:hrn]),
          appointment_time: external_time(r[:apptdate] || r[:newapptdate]), old_appointment_time: external_time(r[:oldapptdate]),
          clinic: r[:clinic], type_status: blank_to_nil(r[:typestatus]), resource_id: r[:resourceid].to_i,
          made_by: blank_to_nil(r[:appt_made_by]), made_on: external_time(r[:date_appt_made])&.to_date, note: blank_to_nil(r[:note]),
          street: blank_to_nil(r[:street]), city: blank_to_nil(r[:city]), state: blank_to_nil(r[:state]),
          zip: blank_to_nil(r[:zip]), home_phone: blank_to_nil(r[:homephone]) }
      end
    end
  end
end
