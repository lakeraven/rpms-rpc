# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"

# Hermetic tests for the registration edits of rpms-ops#1055: the address
# history (rpms-ux S-REG-21.1), the cell phone (S-REG-21.5) and race and
# ethnicity (S-REG-20.2 to 20.4), filed with DDR FILER inside AG's edit lock
# under the rules of rpms-rpc#549.
class RegistrationEditsTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  FM = RpmsRpc::FilemanDateParser
  RS = "\x1e"
  US = "\x1f"
  LOCK_OK = "I00010RESULT^T00080MESSAGE#{RS}1^#{RS}#{US}"
  LOCK_HELD = "I00010RESULT^T00080MESSAGE#{RS}0^Held by DEMO,USER.#{RS}#{US}"
  UPDATE_OK = "I00010RESULT^T01024ERROR^T01024OTHER_PARMS#{RS}1^^#{RS}#{US}"
  DFN = 990_042

  def setup
    @mock = RpmsRpc.mock!
    @mock.set_authenticated("501")
  end

  def teardown
    RpmsRpc.reset!
  end

  def rpcs_sent = @mock.received_calls.map { |c| c[:rpc] }.reject { |rpc| rpc.start_with?("XWB", "CIA") }
  def filer_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  def today = FM.to_fileman(Date.today)

  def seed_lock(reply = LOCK_OK)
    @mock.seed(:agg_lock_patient, DFN.to_s, reply)
    @mock.seed(:agg_unlock_patient, DFN.to_s, LOCK_OK)
  end

  def seed_gets(file, iens, fields, text, flags: "I")
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_lister(text, **param)
    @mock.seed(:ddr_lister, Ddr.lister_param(**param).to_s, text)
  end

  # -- address history (S-REG-21.1) ------------------------------------------

  def address_reply(line1:, city: "ANYWHERE", dob: "2520526")
    rows = { ".03" => dob, ".111" => line1, ".112" => "", ".113" => "", ".114" => city, ".115" => "27",
             ".116" => "59000", ".1112" => "590001234", ".131" => "406-555-0100" }
    lines = rows.map do |field, value|
      external = field == ".1112" ? "59000-1234" : value
      "2^#{DFN},^#{field}^#{value}^#{external}"
    end
    "[Data]\n#{lines.join("\n")}"
  end

  # The address is read before and after AGG UPDATE PATIENT, with the same
  # parameters, so the mock answers from a queue.
  def with_address_reads(*replies)
    original = Ddr.method(:gets_entry)
    test = self
    Ddr.define_singleton_method(:gets_entry) do |file:, iens:, fields:, flags: ""|
      test.seed_gets("2", iens, fields, replies.shift, flags: flags) if file == "2" && fields == Reg::ADDRESS_READ_FIELDS
      original.call(file: file, iens: iens, fields: fields, flags: flags)
    end
    yield
  ensure
    Ddr.singleton_class.send(:remove_method, :gets_entry)
  end

  def seed_date_from(value = "")
    seed_gets("9000001", "#{DFN},", "7911", "[Data]\n9000001^#{DFN},^7911^#{value}^#{value}")
  end

  def test_s_reg_21_1_files_the_address_then_keeps_the_old_one_with_the_date_they_moved
    seed_lock
    seed_date_from("3200101")
    @mock.seed(:agg_update_patient, "Address", UPDATE_OK)
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^1")
    moved = Date.today - 3

    result = with_address_reads(address_reply(line1: "1 OLD RD"), address_reply(line1: "2 NEW RD")) do
      Reg.change_address(DFN, moved_on: moved, address_line1: "2 NEW RD")
    end

    assert_equal({ success: true, dfn: DFN, history: true }, result)
    assert_equal [ "AGG LOCK PATIENT", "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "AGG UPDATE PATIENT",
                   "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "DDR FILER", "AGG UNLOCK PATIENT" ], rpcs_sent
    node = "+1,#{DFN},"
    rows = filer_calls.first[:params][1].values
    assert_equal [ "9000001.83^.01^#{node}^#{today}", "9000001.83^.02^#{node}^1 OLD RD", "9000001.83^.05^#{node}^ANYWHERE",
                   "9000001.83^.06^#{node}^27", "9000001.83^.07^#{node}^59000-1234", "9000001.83^.08^#{node}^406-555-0100",
                   "9000001.83^.11^#{node}^3200101", "9000001.83^.12^#{node}^#{FM.to_fileman(moved)}",
                   "9000001^7911^#{DFN},^#{FM.to_fileman(moved)}" ], rows
  end

  def test_s_reg_21_1_an_unchanged_address_keeps_no_history
    seed_lock
    seed_date_from
    @mock.seed(:agg_update_patient, "Address", UPDATE_OK)

    result = with_address_reads(address_reply(line1: "1 OLD RD"), address_reply(line1: "1 OLD RD")) do
      Reg.change_address(DFN, phone_work: "406-555-0199")
    end

    assert_equal({ success: true, dfn: DFN, history: false }, result)
    assert_empty filer_calls
  end

  def test_s_reg_21_1_a_failed_read_files_nothing_and_unlocks
    seed_lock
    seed_gets("2", "#{DFN},", Reg::ADDRESS_READ_FIELDS, "[Data]", flags: "IE")

    result = Reg.change_address(DFN, address_line1: "2 NEW RD")

    assert_equal :lookup_failed, result[:error]
    refute_includes rpcs_sent, "AGG UPDATE PATIENT"
    assert_empty filer_calls
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
  end

  def test_s_reg_21_7_a_date_moved_before_the_date_of_birth_files_nothing
    seed_lock
    seed_date_from

    result = with_address_reads(address_reply(line1: "1 OLD RD", dob: "3000101")) do
      Reg.change_address(DFN, moved_on: Date.new(1990, 1, 1), address_line1: "2 NEW RD")
    end

    assert_equal :invalid, result[:error]
    assert_includes result[:message], "date of birth"
    refute_includes rpcs_sent, "AGG UPDATE PATIENT"
  end

  def test_s_reg_21_1_a_history_refusal_after_the_address_is_filed_is_partial
    seed_lock
    seed_date_from
    @mock.seed(:agg_update_patient, "Address", UPDATE_OK)
    @mock.seed(:ddr_filer, "ADD", "[Data]\n[BEGIN_diERRORS]\n701^1^.02^9000001.83\nThe value is not valid.\n[END_diERRORS]")

    result = with_address_reads(address_reply(line1: "1 OLD RD"), address_reply(line1: "2 NEW RD")) do
      Reg.change_address(DFN, address_line1: "2 NEW RD")
    end

    assert_equal :partial, result[:error]
    assert_includes result[:message], "previous address was not kept"
  end

  def test_s_reg_21_7_refuses_a_future_or_pre_1871_date_and_other_windows_without_an_rpc
    assert_equal :invalid, Reg.change_address(DFN, moved_on: Date.today + 1, city: "X Y")[:error]
    assert_equal :invalid, Reg.change_address(DFN, moved_on: Date.new(1870, 12, 31), city: "X Y")[:error]
    assert_equal :invalid, Reg.change_address(DFN, religion: 3)[:error]
    assert_empty rpcs_sent
  end

  def test_s_reg_21_1_reads_the_history_newest_first
    seed_gets("9000001", "#{DFN},", ".01", "[Data]\n9000001^#{DFN},^.01^#{DFN}^#{DFN}")
    seed_lister("[Data]\n1^3200101^1 OLD RD^^^ANYWHERE^MONTANA^59000^406-555-0100^^\n" \
                "2^3261101^2 MID RD^^^ANYWHERE^MONTANA^59000^^3200101^3261030",
                file: "9000001.83", iens: ",#{DFN},", fields: Reg::ADDRESS_HISTORY_FIELDS, flags: "IP")

    rows = Reg.address_history(DFN)

    assert_equal [ 2, 1 ], rows.map { |r| r[:ien] }
    assert_equal Date.new(2026, 10, 30), rows.first[:lived_to]
    assert_equal Date.new(2020, 1, 1), rows.first[:lived_from]
    assert_equal "MONTANA", rows.last[:state]
  end

  def test_s_reg_21_1_a_failed_history_read_raises
    seed_gets("9000001", "#{DFN},", ".01", "[Data]\n9000001^#{DFN},^.01^#{DFN}^#{DFN}")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.address_history(DFN) }
  end

  # -- cell phone (S-REG-21.5) -----------------------------------------------

  def test_s_reg_21_5_reads_the_cell_phone
    seed_gets("2", "#{DFN},", ".134", "[Data]\n2^#{DFN},^.134^406-555-0101^406-555-0101")

    assert_equal "406-555-0101", Reg.cell_phone(DFN)
  end

  def test_s_reg_21_5_filing_the_cell_phone_is_not_supported_and_sends_no_rpc
    result = Reg.set_cell_phone(DFN, "406-555-0101")

    assert_equal :not_supported, result[:error]
    assert_includes result[:message], "AXENR13"
    assert_empty rpcs_sent
  end

  # -- race and ethnicity (S-REG-20.2 to 20.4) -------------------------------

  def seed_code(file, ien, name, hl7, inactive: "")
    seed_gets(file, "#{ien},", ".01;200;3",
              "[Data]\n#{file}^#{ien},^.01^#{name}^#{name}\n#{file}^#{ien},^200^#{inactive}^\n#{file}^#{ien},^3^#{hl7}^#{hl7}")
  end

  def seed_method(ien)
    seed_gets("10.3", "#{ien},", ".01", "[Data]\n10.3^#{ien},^.01^M#{ien}^M#{ien}")
  end

  def seed_stored(file, rows)
    seed_lister("[Data]\n#{rows.join("\n")}", file: file, iens: ",#{DFN},", fields: "@;.02I", flags: "IP")
  end

  def seed_race_world
    seed_lock
    seed_code("10", 2, "AMERICAN INDIAN OR ALASKA NATIVE", "1002-5")
    seed_code("10", 14, "WHITE", "2106-3")
    seed_code("10", 11, "DECLINED TO ANSWER", "0000-0")
    seed_code("10", 3, "WHITE, NOT OF HISPANIC ORIGIN", "", inactive: "1")
    seed_code("10.2", 2, "NOT HISPANIC OR LATINO", "2186-5")
    [ 1, 2 ].each { |ien| seed_method(ien) }
  end

  def test_s_reg_20_2_replaces_the_races_and_ethnicities_in_one_filer_add_inside_the_lock
    seed_race_world
    seed_stored("2.02", [ "14^3", "9^1" ])
    seed_stored("2.06", [])
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^2")

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 }, { code: 14, method: 2 } ],
                                         ethnicities: [ { code: 2, method: 1 } ])

    assert_equal({ success: true }, result)
    assert_equal "AGG LOCK PATIENT", rpcs_sent.first
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
    params = filer_calls.first[:params]
    assert_equal "ADD", params[0]
    assert_equal [ "2.02^.01^9,#{DFN},^@",
                   "2.02^.01^+1,#{DFN},^2", "2.02^.02^+1,#{DFN},^1", "2.02^.02^14,#{DFN},^2",
                   "2.06^.01^+2,#{DFN},^2", "2.06^.02^+2,#{DFN},^1",
                   "9000001^.03^#{DFN},^#{today}", "9000001^.12^#{DFN},^501", "9000001^.16^#{DFN},^#{today}" ],
                 params[1].values
    assert_equal({ 1 => "2", 2 => "2" }, params[3])
  end

  def test_s_reg_20_4_declined_beside_another_race_is_refused_and_files_nothing
    seed_race_world

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 11, method: 1 }, { code: 14, method: 1 } ],
                                         ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :invalid, result[:error]
    assert_empty filer_calls
  end

  def test_s_reg_20_2_an_inactive_race_is_refused_and_files_nothing
    seed_race_world

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 3, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :invalid, result[:error]
    assert_includes result[:message], "no longer an active race"
    assert_empty filer_calls
  end

  def test_s_reg_20_3_and_20_4_refuse_an_empty_or_repeated_list_without_an_rpc
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

  def test_s_reg_20_2_a_held_lock_sends_no_ddr_call
    seed_lock(LOCK_HELD)

    result = Reg.set_race_ethnicity(DFN, races: [ { code: 2, method: 1 } ], ethnicities: [ { code: 2, method: 1 } ])

    assert_equal :lock_failed, result[:error]
    refute(rpcs_sent.any? { |rpc| rpc.start_with?("DDR") })
  end

  def test_s_reg_20_2_reads_races_and_ethnicities_with_their_methods
    seed_gets("9000001", "#{DFN},", ".01", "[Data]\n9000001^#{DFN},^.01^#{DFN}^#{DFN}")
    seed_lister("[Data]\n2^AMERICAN INDIAN OR ALASKA NATIVE^1^SELF IDENTIFICATION",
                file: "2.02", iens: ",#{DFN},", fields: "@;.01E;.02I;.02E", flags: "IP")
    seed_lister("[Data]\n2^NOT HISPANIC OR LATINO^2^PROXY",
                file: "2.06", iens: ",#{DFN},", fields: "@;.01E;.02I;.02E", flags: "IP")

    read = Reg.race_ethnicity(DFN)

    assert_equal [ { ien: 2, name: "AMERICAN INDIAN OR ALASKA NATIVE", method: 1, method_name: "SELF IDENTIFICATION" } ], read[:races]
    assert_equal "PROXY", read[:ethnicities].first[:method_name]
  end
end
