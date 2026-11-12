# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# The registration edits of openrpms#1055, filed inside AG's edit lock and
# read back through FileMan: the address history (rpms-ux S-REG-21.1) and
# race and ethnicity (S-REG-20.2 to 20.4). The cell phone (S-REG-21.5) is
# read only: DDR FILER cannot file #2 .134 (its AXENR13 index needs DFN).
class RegistrationEditsLiveTest < LiveSpec::Test
  writes!

  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  ADDRESS_DFN = 990_009 # INDIA,QUINN, a synthetic seed patient
  RACE_DFN = 990_010    # JULIETT,SAM, a synthetic seed patient

  def fileman(file, iens, fields)
    reply = Ddr.gets_entry(file: file, iens: iens, fields: fields, flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    refute reply[:error], "DDR GETS ENTRY DATA refused ##{file} #{iens}"
    reply[:fields].transform_values { |value| value[:internal] }
  end

  def test_s_reg_21_1_a_changed_address_keeps_the_old_one_ended_on_the_date_moved
    old = fileman("2", "#{ADDRESS_DFN},", ".111;.114;.115;.131")
    before = Reg.address_history(ADDRESS_DFN)
    moved = Date.today - 2

    result = Reg.change_address(ADDRESS_DFN, moved_on: moved, address_line1: "12 LIVE TEST RD", city: "ELSEWHERE")

    assert_equal({ success: true, dfn: ADDRESS_DFN, history: true }, result)
    assert_equal({ ".111" => "12 LIVE TEST RD", ".114" => "ELSEWHERE" }, fileman("2", "#{ADDRESS_DFN},", ".111;.114"))
    history = Reg.address_history(ADDRESS_DFN)
    assert_equal before.size + 1, history.size
    kept = history.first
    entry = fileman("9000001.83", "#{kept[:ien]},#{ADDRESS_DFN},", ".01;.02;.05;.06;.08;.12")
    assert_equal({ ".01" => RpmsRpc::FilemanDateParser.to_fileman(Date.today), ".02" => old[".111"], ".05" => old[".114"],
                   ".06" => old[".115"], ".08" => old[".131"], ".12" => RpmsRpc::FilemanDateParser.to_fileman(moved) }, entry)
    assert_equal RpmsRpc::FilemanDateParser.to_fileman(moved), fileman("9000001", "#{ADDRESS_DFN},", "7911")["7911"]

    unchanged = Reg.change_address(ADDRESS_DFN, phone_work: "406-555-0177")
    assert_equal false, unchanged[:history]
    assert_equal history.size, Reg.address_history(ADDRESS_DFN).size
  ensure
    if client && old
      Reg.change_address(ADDRESS_DFN, address_line1: old[".111"], city: old[".114"])
    end
  end

  def test_s_reg_21_7_a_date_moved_in_the_future_files_nothing
    before = fileman("2", "#{ADDRESS_DFN},", ".111")

    assert_equal :invalid, Reg.change_address(ADDRESS_DFN, moved_on: Date.today + 1, address_line1: "99 NEVER RD")[:error]
    assert_equal before, fileman("2", "#{ADDRESS_DFN},", ".111")
  end

  def test_s_reg_21_5_the_cell_phone_is_read_and_its_write_is_not_supported
    assert_kind_of String, Reg.cell_phone(ADDRESS_DFN)
    assert_equal :not_supported, Reg.set_cell_phone(ADDRESS_DFN, "406-555-0101")[:error]
  end

  def test_s_reg_20_2_races_and_ethnicities_file_with_their_methods_and_read_back
    choices = Reg.race_ethnicity_choices
    race = choices[:races].find { |r| r[:name] == "AMERICAN INDIAN OR ALASKA NATIVE" }
    white = choices[:races].find { |r| r[:name] == "WHITE" }
    not_hispanic = choices[:ethnicities].find { |e| e[:name] == "NOT HISPANIC OR LATINO" }
    self_id = choices[:methods].find { |m| m[:name] == "SELF IDENTIFICATION" }
    proxy = choices[:methods].find { |m| m[:name] == "PROXY" }
    [ race, white, not_hispanic, self_id, proxy ].each { |found| refute_nil found, "a demo race, ethnicity or method is missing" }

    result = Reg.set_race_ethnicity(RACE_DFN, races: [ { code: race[:ien], method: self_id[:ien] }, { code: white[:ien], method: proxy[:ien] } ],
                                              ethnicities: [ { code: not_hispanic[:ien], method: self_id[:ien] } ])
    assert_equal({ success: true }, result)
    assert_equal({ ".01" => race[:ien].to_s, ".02" => self_id[:ien].to_s }, fileman("2.02", "#{race[:ien]},#{RACE_DFN},", ".01;.02"))
    assert_equal({ ".01" => white[:ien].to_s, ".02" => proxy[:ien].to_s }, fileman("2.02", "#{white[:ien]},#{RACE_DFN},", ".01;.02"))
    assert_equal({ ".01" => not_hispanic[:ien].to_s, ".02" => self_id[:ien].to_s },
                 fileman("2.06", "#{not_hispanic[:ien]},#{RACE_DFN},", ".01;.02"))

    narrowed = Reg.set_race_ethnicity(RACE_DFN, races: [ { code: white[:ien], method: self_id[:ien] } ],
                                                ethnicities: [ { code: not_hispanic[:ien], method: self_id[:ien] } ])
    assert_equal({ success: true }, narrowed)
    read = Reg.race_ethnicity(RACE_DFN)
    assert_equal [ [ white[:ien], self_id[:ien] ] ], read[:races].map { |r| [ r[:ien], r[:method] ] }
    assert_equal "WHITE", read[:races].first[:name]
  end

  def test_s_reg_20_4_declined_beside_another_race_files_nothing
    choices = Reg.race_ethnicity_choices
    declined = choices[:races].find { |r| r[:name] == "DECLINED TO ANSWER" }
    white = choices[:races].find { |r| r[:name] == "WHITE" }
    ethnicity = choices[:ethnicities].first
    before = Reg.race_ethnicity(RACE_DFN)

    result = Reg.set_race_ethnicity(RACE_DFN, races: [ { code: declined[:ien], method: 1 }, { code: white[:ien], method: 1 } ],
                                              ethnicities: [ { code: ethnicity[:ien], method: 1 } ])

    assert_equal :invalid, result[:error]
    assert_equal before, Reg.race_ethnicity(RACE_DFN)
  end
end
