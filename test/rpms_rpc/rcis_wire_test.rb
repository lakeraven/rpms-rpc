# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/rcis_wire"

# The RCIS (BMC) wire convention (#210), from the routines on the built image
# (same text as FOIA Referred Care Information System/Routines).
class RcisWireTest < Minitest::Test
  W = RpmsRpc::RcisWire

  # SETREFRL^BMCRPC2: S RSLT="~`1^"_NREFIEN (BMCRPC2.m:155)
  def test_write_success_carries_the_new_ien
    assert_equal({ success: true, code: "1", ien: "3001", message: nil }, W.result("~`1^3001"))
  end

  # SETREFRL^BMCRPC2: S RSLT="~`0^Required field missing" (BMCRPC2.m:58)
  def test_write_failure_carries_the_message
    assert_equal({ success: false, code: "0", ien: nil, message: "Required field missing" },
                 W.result("~`0^Required field missing"))
  end

  # SETREFRL^BMCRPC2 duplicate check: "~`-1^Referral# ... (Y/N)?" (BMCRPC2.m:69)
  def test_duplicate_prompt_is_not_success
    r = W.result("~`-1^Referral# 123 has been found with the same information, do you want to create another referral (Y/N)?")
    refute r[:success]
    assert_equal "-1", r[:code]
    assert_match(/Referral# 123/, r[:message])
  end

  # UPDREFRL^BMCRPC2 closes with a bare "~`1" (BMCRPC2.m:175)
  def test_bare_success
    assert_equal({ success: true, code: "1", ien: nil, message: nil }, W.result("~`1"))
  end

  def test_result_is_nil_without_the_sigil
    assert_nil W.result("1^3001")
    assert_nil W.result(nil)
  end

  # PROV^BMCRPC4 builds one node: "-1^All~" then IEN^NAME~ per user (BMCRPC4.m:136-141)
  def test_records_split_on_tilde_and_drop_the_trailing_empty
    assert_equal [ "-1^All", "17^DOCTOR,ONE", "42^NURSE,TWO" ], W.records("-1^All~17^DOCTOR,ONE~42^NURSE,TWO~")
  end

  def test_records_strip_the_leading_sigil
    assert_equal [ "5^A", "6^B" ], W.records("~`5^A~`6^B")
  end

  def test_records_of_nothing
    assert_equal [], W.records(nil)
    assert_equal [], W.records("")
  end
end
