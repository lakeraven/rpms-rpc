# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"

# A patient's advance directives (rpms-ux S-REG-17), in the DATE OF ENTRY
# multiple (#9000040.11) of ADVANCE DIRECTIVE (#9000040), and the registration
# warning AG*7.1*17 adds for a patient with none (AG error 55, WADD^AGEDERR4).
# Each write is read back through FileMan with DDR GETS ENTRY DATA, not through
# the gem's own read, and the spec removes what it adds.
class RegistrationAdvanceDirectivesLiveTest < LiveSpec::Test
  writes!

  DFN = 990_046 # VANTAGE,TAYLOR, a synthetic seed patient no other live spec writes to
  REG = RpmsRpc::Registration
  WARNING = "55" # Advance Directives missing (#9009061.5 entry 55, AG*7.1*17)

  def setup
    super
    @types = REG.advance_directive_types
    refute_empty @types, "the demo file has advance-directive types (#9000030 .02 holds A)"
    clear
  end

  def teardown
    clear if client
    super
  end

  def clear
    REG.advance_directives(DFN).each { |row| REG.remove_advance_directive(DFN, row[:ien]) }
  end

  def warnings
    RpmsRpc::Agg.edit_check(dfn: DFN)[:checks].map { |check| check[:hide_error_num].to_s }
  end

  # FileMan's own read of one entry: { ".01" =>, ".02" =>, ".03" =>, ".04" => }, internal values.
  def filed(ien)
    reply = RpmsRpc::ContextScope.scoped(RpmsRpc.client, REG::CONTEXT) do
      RpmsRpc::DdrFileman.gets_entry(file: "9000040.11", iens: "#{ien},#{DFN},", fields: ".01;.02;.03;.04", flags: "I")
    end
    refute reply[:error], "FileMan has no #9000040.11 entry #{ien},#{DFN},"
    reply[:fields].transform_values { |value| value[:internal].to_s }
  end

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  def test_s_reg_17_1_a_directive_is_filed_with_its_type_and_date
    living_will = @types.first
    on = Date.new(2026, 11, 2)

    assert_equal({ success: true }, REG.record_advance_directive(DFN, directive: true, type: living_will[:ien], entered_on: on))

    row = REG.advance_directives(DFN).first
    assert_equal [ true, living_will[:ien], living_will[:name], on, nil ],
                 row.values_at(:directive, :type_ien, :type, :entered_on, :reason)
    assert_equal({ ".01" => fm(on), ".02" => "Y", ".03" => living_will[:ien].to_s, ".04" => "" }, filed(row[:ien]))
  end

  def test_s_reg_17_2_and_17_8_no_directive_with_a_reason_clears_the_intake_warning
    assert_includes warnings, WARNING, "AG warns when the patient has no advance directive on file"

    assert REG.record_advance_directive(DFN, directive: false, reason: "PATIENT HAS NONE")[:success]

    row = REG.advance_directives(DFN).first
    assert_equal({ ".01" => fm(RpmsRpc::ServerClock.today), ".02" => "N", ".03" => "", ".04" => "PATIENT HAS NONE" },
                 filed(row[:ien]))
    refute_includes warnings, WARNING, "AG's edit check no longer warns once an answer is on file"

    assert REG.remove_advance_directive(DFN, row[:ien])[:success]
    assert_includes warnings, WARNING, "removing the last entry brings the warning back"
  end

  def test_s_reg_17_3_the_same_type_on_the_same_date_is_refused
    type = @types.first[:ien]
    on = Date.new(2026, 11, 3)
    assert REG.record_advance_directive(DFN, directive: true, type: type, entered_on: on)[:success]

    refused = REG.record_advance_directive(DFN, directive: true, type: type, entered_on: on)

    assert_equal :invalid, refused[:error]
    assert_equal 1, REG.advance_directives(DFN).size
  end

  def test_s_reg_17_4_a_missing_type_or_reason_is_refused_and_names_it
    assert_match(/Type/, REG.record_advance_directive(DFN, directive: true)[:message])
    assert_match(/Reason/, REG.record_advance_directive(DFN, directive: false)[:message])
    assert_match(/Reason/, REG.record_advance_directive(DFN, directive: false, reason: "NO")[:message])
    assert_match(/Type is not/, REG.record_advance_directive(DFN, directive: true, type: 999_999)[:message])
    assert_empty REG.advance_directives(DFN)
  end

  def test_s_reg_17_6_and_17_7_a_directive_is_changed_and_then_ended
    type = @types.first[:ien]
    on = Date.new(2026, 11, 4)
    assert REG.record_advance_directive(DFN, directive: false, reason: "WILL BRING A COPY", entered_on: on)[:success]
    ien = REG.advance_directives(DFN).first[:ien]

    assert REG.change_advance_directive(DFN, ien, directive: true, type: type, entered_on: on)[:success]
    assert_equal({ ".01" => fm(on), ".02" => "Y", ".03" => type.to_s, ".04" => "" }, filed(ien))
    assert_equal 1, REG.advance_directives(DFN).size

    ended = Date.new(2026, 11, 5)
    assert REG.record_advance_directive(DFN, directive: false, reason: "REVOKED BY PATIENT", entered_on: ended)[:success]
    latest, earlier = REG.advance_directives(DFN)
    assert_equal [ ended, false, "REVOKED BY PATIENT" ], latest.values_at(:entered_on, :directive, :reason)
    assert_equal({ ".01" => fm(on), ".02" => "Y", ".03" => type.to_s, ".04" => "" }, filed(earlier[:ien]))
  end

  def test_s_reg_17_5_an_entry_entered_in_error_is_removed
    assert REG.record_advance_directive(DFN, directive: false, reason: "PATIENT DECLINED")[:success]
    ien = REG.advance_directives(DFN).first[:ien]

    assert REG.remove_advance_directive(DFN, ien)[:success]

    assert_empty REG.advance_directives(DFN)
    assert_equal :not_found, REG.remove_advance_directive(DFN, ien)[:error]
  end
end
