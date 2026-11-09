# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"
require_relative "../captured_replies"

# The registration edits of rpms-ops#1055: the address history (rpms-ux
# S-REG-21.1), the cell phone (S-REG-21.5) and race and ethnicity (S-REG-20.2
# to 20.4), filed with DDR FILER inside AG's edit lock under the rules of
# rpms-rpc#549.
#
# Each test replays one recorded flow (test/fixtures/captured_replies/
# registration-edits.yml): the gem run as PROFILE,REG (DUZ 207) on seed
# patient DFN 990009 on the pinned build, with every reply it got, in order.
# The gem dates some rows with the client's today, so where a recorded frame
# carries the capture's day, the replay expects today in its place; every
# other piece of each frame must be exactly what the gem sent the build.
class RegistrationEditsTest < Minitest::Test
  Reg = RpmsRpc::Registration
  FM = RpmsRpc::FilemanDateParser
  SLUG = "registration-edits"
  DFN = 990_009
  DUZ = "207"

  def self.filer_value(flow, row) = CapturedReplies.flow_calls(SLUG, flow).find { |rpc, _| rpc == "DDR FILER" }.last[1].fetch(row)
  # The day the flows ran: the date the first history row was filed under.
  CAPTURE_DAY = FM.parse_date(filer_value("move_first", 1).split("^").last)

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @flow = flow
    script = flow ? CapturedReplies.flow_script(SLUG, flow) : {}
    @client = CapturedReplies::ReplayCiaClient.new(script).signed_on_as(DUZ)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def today = FM.to_fileman(Date.today)

  # A recorded value with the capture's day in it, as the gem builds it today.
  def as_of_today(value)
    case value
    when String then value.gsub(FM.to_fileman(CAPTURE_DAY), today)
    when Array then value.map { |v| as_of_today(v) }
    when Hash then value.to_h { |k, v| [ k, as_of_today(v) ] }
    else value
    end
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def rpcs_sent = sent.map(&:first)
  def filer_calls = sent.select { |rpc, _| rpc == "DDR FILER" }

  # The gem sent exactly the calls of the flow it replays, frame for frame.
  def assert_sends_the_recorded_flow
    assert_equal as_of_today(CapturedReplies.flow_calls(SLUG, @flow)), sent
  end

  # -- address history (S-REG-21.1) ------------------------------------------

  def test_s_reg_21_1_files_the_address_then_keeps_the_old_one_with_the_date_they_moved
    replay("move_second")

    result = Reg.change_address(DFN, moved_on: CAPTURE_DAY - 3, address_line1: "3 NEWER RD")

    assert_equal({ success: true, dfn: DFN, history: true }, result)
    assert_equal [ "AGG LOCK PATIENT", "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "AGG UPDATE PATIENT",
                   "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "DDR FILER", "AGG UNLOCK PATIENT" ], rpcs_sent
    node = "+1,#{DFN},"
    moved = FM.to_fileman(CAPTURE_DAY - 3)
    assert_equal [ "9000001.83^.01^#{node}^#{today}", "9000001.83^.02^#{node}^2 NEW RD",
                   "9000001.83^.05^#{node}^ANYWHERE", "9000001.83^.06^#{node}^27", "9000001.83^.07^#{node}^59000",
                   "9000001.83^.08^#{node}^406-555-1009", "9000001.83^.11^#{node}^#{FM.to_fileman(CAPTURE_DAY - 400)}",
                   "9000001.83^.12^#{node}^#{moved}", "9000001^7911^#{DFN},^#{moved}" ], filer_calls.first.last[1].values
    assert_sends_the_recorded_flow
  end

  # The first move: no earlier move date on file, so the kept row has no .11.
  def test_s_reg_21_1_the_first_move_keeps_the_old_address_with_no_start_date
    replay("move_first")

    result = Reg.change_address(DFN, moved_on: CAPTURE_DAY - 400, address_line1: "2 NEW RD")

    assert_equal({ success: true, dfn: DFN, history: true }, result)
    refute(filer_calls.first.last[1].values.any? { |row| row.start_with?("9000001.83^.11^") })
    assert_sends_the_recorded_flow
  end

  def test_s_reg_21_1_an_unchanged_address_keeps_no_history
    replay("unchanged")

    result = Reg.change_address(DFN, phone_work: "406-555-0199")

    assert_equal({ success: true, dfn: DFN, history: false }, result)
    assert_empty filer_calls
    assert_sends_the_recorded_flow
  end

  # AGG LOCK PATIENT answers -1 for a DFN no patient holds: nothing is read
  # or filed.
  def test_s_reg_21_1_a_patient_not_on_file_files_nothing
    replay("address_no_patient")

    result = Reg.change_address(999_999, address_line1: "2 NEW RD")

    refute result[:success]
    assert_equal [ "AGG LOCK PATIENT" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  def test_s_reg_21_7_a_date_moved_before_the_date_of_birth_files_nothing
    replay("before_birth")

    result = Reg.change_address(DFN, moved_on: Date.new(1980, 1, 1), address_line1: "4 EARLY RD")

    assert_equal :invalid, result[:error]
    assert_includes result[:message], "date of birth"
    refute_includes rpcs_sent, "AGG UPDATE PATIENT"
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
    assert_sends_the_recorded_flow
  end

  def test_s_reg_21_7_refuses_a_future_or_pre_1871_date_and_other_windows_without_an_rpc
    replay

    assert_equal :invalid, Reg.change_address(DFN, moved_on: Date.today + 1, city: "X Y")[:error]
    assert_equal :invalid, Reg.change_address(DFN, moved_on: Date.new(1870, 12, 31), city: "X Y")[:error]
    assert_equal :invalid, Reg.change_address(DFN, religion: 3)[:error]
    assert_empty rpcs_sent
  end

  def test_s_reg_21_1_reads_the_history_newest_first
    replay("history")

    rows = Reg.address_history(DFN)

    assert_equal [ 2, 1 ], rows.map { |r| r[:ien] }
    assert_equal({ line1: "2 NEW RD", lived_from: CAPTURE_DAY - 400, lived_to: CAPTURE_DAY - 3 },
                 rows.first.slice(:line1, :lived_from, :lived_to))
    assert_equal({ line1: "163 JUNIPER ST", lived_from: nil, lived_to: CAPTURE_DAY - 400, state: "MONTANA" },
                 rows.last.slice(:line1, :lived_from, :lived_to, :state))
    assert_sends_the_recorded_flow
  end

  def test_s_reg_21_1_a_patient_with_no_moves_has_no_history
    replay("history_empty")

    assert_equal [], Reg.address_history(DFN)
    assert_sends_the_recorded_flow
  end

  # DDR GETS answers [ERROR] for a DFN no patient holds.
  def test_s_reg_21_1_a_failed_history_read_raises
    replay("history_no_patient")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.address_history(999_999) }
    assert_sends_the_recorded_flow
  end

  # -- cell phone (S-REG-21.5) -----------------------------------------------

  def test_s_reg_21_5_reads_the_cell_phone
    replay("cell_phone")

    assert_equal "", Reg.cell_phone(DFN), "DFN 990009 has no cell phone on file"
    assert_sends_the_recorded_flow
  end

  def test_s_reg_21_5_filing_the_cell_phone_is_not_supported_and_sends_no_rpc
    replay

    result = Reg.set_cell_phone(DFN, "406-555-0101")

    assert_equal :not_supported, result[:error]
    assert_includes result[:message], "AXENR13"
    assert_empty rpcs_sent
  end

  # -- race and ethnicity (S-REG-20.2 to 20.4) -------------------------------

  def test_s_reg_20_2_files_the_races_and_ethnicities_in_one_filer_add_inside_the_lock
    replay("races_first")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 14, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal({ success: true }, result)
    assert_equal "AGG LOCK PATIENT", rpcs_sent.first
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
    assert_sends_the_recorded_flow
  end

  # WHITE (14) is on file; the replacement keeps it with a new method and
  # adds AMERICAN INDIAN OR ALASKA NATIVE.
  def test_s_reg_20_2_replaces_the_races_and_ethnicities_in_one_filer_add_inside_the_lock
    replay("races_replace")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 }, { code: 14, method: 2 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal({ success: true }, result)
    mode, rows, _flags, placeholders = filer_calls.first.last
    assert_equal "ADD", mode
    assert_equal [ "2.02^.01^+1,#{DFN},^2", "2.02^.02^+1,#{DFN},^1", "2.02^.02^14,#{DFN},^2",
                   "9000001^.03^#{DFN},^#{today}", "9000001^.12^#{DFN},^#{DUZ}", "9000001^.16^#{DFN},^#{today}" ], rows.values
    assert_equal({ 1 => "2" }, placeholders)
    assert_sends_the_recorded_flow
  end

# AMERICAN INDIAN OR ALASKA NATIVE (2) and WHITE (14) are on file; asking
# for WHITE alone removes the other with FileMan's "@".
def test_s_reg_20_2_a_race_left_out_of_the_list_is_removed
  replay("races_narrow")

  result = Reg.set_race_ethnicity(DFN, races: [ { code: 14, method: 2 } ], ethnicities: [ { code: 2, method: 1 } ])

  assert_equal({ success: true }, result)
  assert_equal [ "2.02^.01^2,#{DFN},^@", "9000001^.03^#{DFN},^#{today}", "9000001^.12^#{DFN},^#{DUZ}",
                 "9000001^.16^#{DFN},^#{today}" ], filer_calls.first.last[1].values
  assert_sends_the_recorded_flow
end

def test_s_reg_20_4_declined_beside_another_race_is_refused_and_files_nothing
    replay("declined_beside_another")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 11, method: 1 }, { code: 14, method: 1 } ],
                                         ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :invalid, result[:error]
    assert_empty filer_calls
    assert_sends_the_recorded_flow
  end

  # Race 3 carries the build's INACTIVE flag (field 200 = 1).
  def test_s_reg_20_2_an_inactive_race_is_refused_and_files_nothing
    replay("inactive_race")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 3, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :invalid, result[:error]
    assert_includes result[:message], "no longer an active race"
    assert_empty filer_calls
    assert_sends_the_recorded_flow
  end

  def test_s_reg_20_3_and_20_4_refuse_an_empty_or_repeated_list_without_an_rpc
    replay

    none = Reg.set_race_ethnicity(DFN, races: [], ethnicities: [ { code: 2, method: 1 } ])
    assert_equal :invalid, none[:error]
    assert_includes none[:message], "race"
    no_ethnicity = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 } ], ethnicities: [])
    assert_includes no_ethnicity[:message], "ethnicity"
    twice = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 }, { code: 2, method: 2 } ],
                                        ethnicities: [ { code: 2, method: 1 } ])
    assert_includes twice[:message], "twice"
    no_method = Reg.set_race_ethnicity(DFN, races: [ { code: 2 } ], ethnicities: [ { code: 2, method: 1 } ])
    assert_equal :invalid, no_method[:error]
    assert_empty rpcs_sent
  end

  # The build's answer while another user holds AG's lock on the patient.
  def test_s_reg_20_2_a_held_lock_sends_no_ddr_call
    replay("lock_held")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :lock_failed, result[:error]
    refute(rpcs_sent.any? { |rpc| rpc.start_with?("DDR") })
    assert_sends_the_recorded_flow
  end

  def test_s_reg_20_2_reads_races_and_ethnicities_with_their_methods
    replay("races_read")

    read = Reg.race_ethnicity(DFN)

    assert_equal [ { ien: 2, name: "AMERICAN INDIAN OR ALASKA NATIVE", method: 1, method_name: "SELF IDENTIFICATION" },
                   { ien: 14, name: "WHITE", method: 2, method_name: "PROXY" } ], read[:races]
    assert_equal [ { ien: 2, name: "NOT HISPANIC OR LATINO", method: 1, method_name: "SELF IDENTIFICATION" } ], read[:ethnicities]
    assert_sends_the_recorded_flow
  end
end
