# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/health_summary"

# HealthSummary.clinical_reminders reads REMIND^ORQQPX's row as the build
# writes it, and reminder_detail sends REMDET(ORY,ORPT,ORIEN)^ORQQPX the
# patient and the reminder as two parameters (rpms-rpc#694). The one
# "DFN^IEN" parameter it used to send left ORIEN undefined and the build died
# in M. Both RPCs are in CIAV VUECENTRIC; the spec reads only.
class HealthSummaryRemindersLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  DFN = 4 # DEMO,PATIENT ONE on the pinned build

  def test_each_listed_reminder_has_a_due_flag_and_its_detail_reads
    reminders = client.with_context(CONTEXT) { RpmsRpc::HealthSummary.clinical_reminders(DFN) }
    refute_empty reminders, "ORQQPX REMINDERS LIST listed no reminder for DFN #{DFN}"

    reminders.each do |reminder|
      assert_includes [ 1, 2, 3, 4 ], reminder[:due_flag], "due flag of #{reminder.inspect}"
      refute reminder.key?(:status), "REMIND has no status piece: #{reminder.inspect}"
    end
    due = reminders.find { |r| r[:due_flag] == 1 }
    refute_nil due, "no due reminder for DFN #{DFN}: #{reminders.inspect}"
    refute_empty due[:due_date].to_s, "a due reminder carries its due date: #{due.inspect}"
    assert_kind_of Integer, due[:priority]

    detail = client.with_context(CONTEXT) { RpmsRpc::HealthSummary.reminder_detail(DFN, due[:ien]) }
    refute_nil detail, "reminder_detail(#{DFN}, #{due[:ien]}) gave no text"
    assert_match(/Frequency:|REMINDER DUE:/, detail[:content])
  end
end
