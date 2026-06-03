# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/client"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

class PatientBriefHeaderTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # BEHOPTCX PTINFO — broad patient identity bundle (test patient #8791)
      m.seed(:patient_ptinfo, "8791", {
        name: "TESTPATIENT,FIRST",
        sex: "F",
        dob_raw: "2860701",          # FileMan: 286 + 1700 = 1986-07-01
        ssn: "XXX-XX-XXXX",
        mrn: "120305",
        designated_team: "Primary Care Team",
        primary_provider: "PROVIDER,DEFAULT"
      })
      m.seed_scalar(:patient_cwad, "8791", "A")  # has allergies, no AD

      # Both sources for the same DFN (composition test)
      m.seed(:patient_ptinfo, "26664", {
        name: "TESTPATIENT,SECOND",
        sex: "M",
        dob_raw: "2700101",          # 1970-01-01
        mrn: "260664",
        designated_team: "Internal Med Team",
        primary_provider: "PROVIDER,OVERRIDDEN"
      })
      m.seed(:patient_designated_provider, "26664", {
        label: "DESIGNATED PRIMARY PROVIDER",
        provider_name: "PROVIDER,FROM_GETBDP",
        provider_ien: 2843,
        title: "PHYSICIAN",
        date_raw: "3260507"
      })
      m.seed_scalar(:patient_cwad, "26664", "AD")  # both flags
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === Contract shape (issue #60) ===

  def test_brief_header_returns_documented_keys_and_nothing_else
    header = RpmsRpc::Patient.brief_header(8791)
    refute_nil header
    expected = %i[name dob sex mrn age allergy_flag ad_flag primary_provider].sort
    assert_equal expected, header.keys.sort, "Return shape must match issue #60 contract"
  end

  def test_brief_header_parses_dob_to_date_object
    header = RpmsRpc::Patient.brief_header(8791)
    assert_kind_of Date, header[:dob]
    assert_equal Date.new(1986, 7, 1), header[:dob]
  end

  def test_brief_header_computes_age_from_dob
    header = RpmsRpc::Patient.brief_header(8791)
    # Assert brief_header's age equals what the helper computes against
    # today — avoids a hard upper bound that ages into the future.
    expected = RpmsRpc::Patient.age_from(header[:dob], today: Date.today)
    assert_kind_of Integer, header[:age]
    assert_equal expected, header[:age]
  end

  # Pin the age computation against a fixed reference date so future
  # regressions in the FileMan-to-age path (off-by-one around birthday,
  # leap year, etc.) are caught precisely without depending on wall-clock.
  def test_age_from_with_fixed_today_returns_exact_year_count
    dob = Date.new(1986, 7, 1)
    assert_equal 39, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 5, 22)),
                 "Before birthday: should be 39"
    assert_equal 40, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 7, 1)),
                 "On birthday: should be 40"
    assert_equal 40, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 7, 2)),
                 "Day after birthday: should be 40"
    assert_equal 39, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 6, 30)),
                 "Day before birthday: should be 39"
    assert_nil RpmsRpc::Patient.age_from(nil), "nil DOB returns nil"
  end

  def test_brief_header_carries_name_sex_mrn_from_ptinfo
    header = RpmsRpc::Patient.brief_header(8791)
    assert_equal "TESTPATIENT,FIRST", header[:name]
    assert_equal "F",                 header[:sex]
    assert_equal "120305",            header[:mrn]
  end

  # === Flags from CWAD ===

  def test_allergy_flag_true_when_cwad_includes_A
    assert_equal true, RpmsRpc::Patient.brief_header(8791)[:allergy_flag]
  end

  def test_ad_flag_false_when_cwad_does_not_include_D
    assert_equal false, RpmsRpc::Patient.brief_header(8791)[:ad_flag]
  end

  def test_both_flags_true_when_cwad_is_AD
    header = RpmsRpc::Patient.brief_header(26664)
    assert_equal true, header[:allergy_flag]
    assert_equal true, header[:ad_flag]
  end

  # === Primary provider precedence ===

  def test_primary_provider_prefers_GETBDP_over_PTINFO
    # PTINFO says "PROVIDER,OVERRIDDEN"; GETBDP says "PROVIDER,FROM_GETBDP".
    # The designated-provider RPC should win.
    header = RpmsRpc::Patient.brief_header(26664)
    assert_equal "PROVIDER,FROM_GETBDP", header[:primary_provider]
  end

  def test_primary_provider_falls_back_to_PTINFO_when_no_GETBDP
    header = RpmsRpc::Patient.brief_header(8791)
    assert_equal "PROVIDER,DEFAULT", header[:primary_provider]
  end

  # === Invalid / unknown DFN handling ===

  def test_brief_header_returns_nil_for_invalid_dfn
    assert_nil RpmsRpc::Patient.brief_header(nil)
    assert_nil RpmsRpc::Patient.brief_header(0)
    assert_nil RpmsRpc::Patient.brief_header(-5)
  end

  def test_brief_header_returns_nil_for_unknown_dfn
    assert_nil RpmsRpc::Patient.brief_header(999999)
  end

  # === Regression ===

  def test_existing_patient_find_still_works
    RpmsRpc.reset!
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "TEST,ONE", sex: "F", age: 30 })
    end
    refute_nil RpmsRpc::Patient.find(1)
  end

  # === Broker error tolerance (issue #117) ===
  #
  # `brief_header` routes through BEHO* RPCs (BHS package). If the target
  # Broker doesn't have BHS installed, the underlying call raises RpcError
  # ("<NOLINE>" / "doesn't exist"). brief_header should treat that as
  # "feature unavailable on this Broker" and return nil cleanly — silent
  # garbage projection was the failure mode in #117.

  def test_brief_header_returns_nil_when_broker_raises_rpc_error
    raising_client = Class.new do
      def call_rpc(*)
        raise RpmsRpc::Client::RpcError, "M  ERROR=<NOLINE>PTINFO+22 BEHOPTCX"
      end
    end.new

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = raising_client }

    assert_nil RpmsRpc::Patient.brief_header(8791)
  end

  def test_brief_header_returns_nil_for_remote_procedure_not_found
    raising_client = Class.new do
      def call_rpc(*)
        raise RpmsRpc::Client::RpcError, "Remote Procedure 'BEHOPTCX PTINFO' doesn't exist"
      end
    end.new

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = raising_client }

    assert_nil RpmsRpc::Patient.brief_header(8791)
  end

  # Genuine M-runtime errors (e.g., <UNDEFINED>, <SUBSCRIPT>) and permission
  # failures indicate a real problem, not "feature unavailable". They must
  # propagate so they aren't silently masked.
  def test_brief_header_propagates_non_missing_routine_rpc_errors
    raising_client = Class.new do
      def call_rpc(*)
        raise RpmsRpc::Client::RpcError, "M  ERROR=<UNDEFINED>FOO+5^XYZ^"
      end
    end.new

    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = raising_client }

    err = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Patient.brief_header(8791)
    end
    assert_includes err.message, "UNDEFINED"
  end
end
