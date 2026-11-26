# frozen_string_literal: true

require "rpms_rpc/api/scheduling_lookups"

# The scheduling client's lookups beside the calendar, as
# RpmsRpc::Scheduling sends them under BSDXRPC, recorded as flows as the
# scheduler test role on the demo image. The booked flows run in order: one
# appointment for the panel patient TANGO,MARLOWE (DFN 990020) at DEMO
# PRIMARY CARE on 01/13/2027 10:00, read in the event log, the letter list and the overlaps, then
# cancelled by the clinic and read on the cancellation list.
S = RpmsRpc::Scheduling
SLOT = Time.new(2027, 1, 13, 10, 0, 0)
BOOKED = {} # rubocop:disable Style/MutableConstant -- the flows below share the booking
CAPTURE = {
  rpc: "BSDX SCHEDULE USER", entry_point: "SCHUSR^BSDX17",
  signed_on_as: "PROFILE,SCHED (PSCH123, the scheduler test role's published demo pair)",
  access: "PSCH123", verify: "PSCH123!!",
  note: "Run on a throwaway container. The booking flows book one appointment and cancel it; the cancelled " \
        "appointment stays on file, as every cancellation does.",
  flows: {
    "schedule_users" => { about: "Scheduling.schedule_users", run: -> { S.schedule_users } },
    "scheduling_manager" => { about: "Scheduling.scheduling_manager?: the scheduler", run: -> { S.scheduling_manager? } },
    "scheduling_manager_operator" => { about: "Scheduling.scheduling_manager?(duz: 4): the operator",
                                       run: -> { S.scheduling_manager?(duz: 4) } },
    "resource_groups" => { about: "Scheduling.user_resource_groups", run: -> { S.user_resource_groups } },
    "user_resource_group_members" => { about: "Scheduling.user_resource_group_members", run: -> { S.user_resource_group_members } },
    "resource_letters" => { about: "Scheduling.resource_letters([1, 2])", run: -> { S.resource_letters([ 1, 2 ]) } },
    "no_show_count" => { about: "Scheduling.no_show_count(990017, 3)", run: -> { S.no_show_count(990_017, 3) } },
    "patient_lookup" => { about: "Scheduling.patient_lookup(QUEBEC,SAGE)", run: -> { S.patient_lookup("QUEBEC,SAGE") } },
    "access_block_overlaps" => { about: "Scheduling.access_block_overlaps on DEMO PRIMARY CARE, 01/13/2027 09:00-10:00",
                                 run: lambda {
                                   S.access_block_overlaps(resource: "DEMO PRIMARY CARE", start_time: SLOT - 3600, end_time: SLOT)
                                 } },
    "wellness_handout_types" => { about: "Scheduling.wellness_handout_types", run: -> { S.wellness_handout_types } },
    "book" => { about: "Scheduling.add_appointment: DFN 990020 at DEMO PRIMARY CARE, 01/13/2027 10:00, 20 minutes",
                run: lambda {
                  BOOKED[:id] = S.add_appointment(patient_dfn: 990_020, resource: "DEMO PRIMARY CARE", start_time: SLOT,
                                                  end_time: SLOT + 1200, length_minutes: 20)[:appointment_id]
                } },
    "appointment_events" => { about: "Scheduling.appointment_events(990020)", run: -> { S.appointment_events(990_020) } },
    "appointment_letter_list" => { about: "Scheduling.appointment_letter_list([1]) on 01/13/2027",
                          run: -> { S.appointment_letter_list([ 1 ], start_date: SLOT.to_date, end_date: SLOT.to_date) } },
    "appointment_overlaps" => { about: "Scheduling.appointment_overlaps on DEMO PRIMARY CARE at the booking",
                                run: -> { S.appointment_overlaps(resource: "DEMO PRIMARY CARE", start_time: SLOT, end_time: SLOT + 1200) } },
    "cancel" => { about: "Scheduling.cancel_appointment: cancelled by the clinic (reason 13)",
                  run: -> { S.cancel_appointment(BOOKED.fetch(:id), reason: "13", type: "C", note: "capture") } },
    "cancellation_letter_list" => { about: "Scheduling.cancellation_letter_list([1]) on 01/13/2027",
                                 run: -> { S.cancellation_letter_list([ 1 ], start_date: SLOT.to_date, end_date: SLOT.to_date) } }
  }
}.freeze
