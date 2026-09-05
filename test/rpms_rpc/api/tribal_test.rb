# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/eligibility"

# Tests for tribal/IHS symbolic APIs. All reads run on the generic
# FileMan RPCs (DDR GETS ENTRY DATA / DDR LISTER / DDR VALIDATOR) over
# the real files: #9000001 IHS PATIENT, TRIBE #9999999.03, SERVICE UNIT
# #9999999.22. Seeds use the raw DDR reply grammars (bracket markers +
# GETS^DIQ FILE^IEN^FIELD^INTERNAL^EXTERNAL rows). All data is synthetic.
class TribalTest < Minitest::Test
  Ddr = RpmsRpc::DdrFileman
  Tribal = RpmsRpc::Tribal

  def setup
    @mock = RpmsRpc.mock! do |m|
      m.seed(:vfc_eligibility, "1", { code: "V04", label: "AI/AN" })
      m.seed_collection(:vfc_eligibility_list, [
        { code: "V01", label: "Not VFC eligible" },
        { code: "V04", label: "AI/AN" }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # -- seeding helpers (raw DDR reply grammars) ------------------------------

  def seed_gets(file:, iens:, fields:, text:)
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: "IE").to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_patient_tribal(dfn: 1)
    seed_gets(file: "9000001", iens: "#{dfn},", fields: Tribal::ENROLLMENT_FIELDS, text: <<~REPLY.strip)
      [Data]
      9000001^#{dfn}^.07^EX-12345^EX-12345
      9000001^#{dfn}^1108^123^EXAMPLE TRIBE
      9000001^#{dfn}^1109^1/2^1/2
      9000001^#{dfn}^1110^1/2^1/2
      9000001^#{dfn}^1111^13^INDIAN/ALASKA NATIVE
      9000001^#{dfn}^1112^I^INDIAN/ALASKA NATIVE
      9000001^#{dfn}^1118^EXAMPLE COMMUNITY^EXAMPLE COMMUNITY
    REPLY
  end

  # -- enrollment ------------------------------------------------------------

  def test_enrollment_projects_9000001_tribal_fields
    seed_patient_tribal

    result = Tribal.enrollment(1)

    refute_nil result
    assert_equal "EX-12345", result[:enrollment_number]
    assert_equal 123, result[:tribe_ien]
    assert_equal "EXAMPLE TRIBE", result[:tribe_name]
    assert_equal "1/2", result[:tribe_quantum]
    assert_equal "1/2", result[:indian_blood_quantum]
    assert_equal 13, result[:classification_ien]
    assert_equal "INDIAN/ALASKA NATIVE", result[:classification]
    assert_equal "I", result[:eligibility_status]
    assert_equal "EXAMPLE COMMUNITY", result[:community]
  end

  def test_enrollment_returns_nil_for_unknown_dfn
    seed_gets(file: "9000001", iens: "999,", fields: Tribal::ENROLLMENT_FIELDS, text: "[ERROR]")

    assert_nil Tribal.enrollment(999)
  end

  def test_enrollment_returns_nil_when_broker_gives_no_response
    assert_nil Tribal.enrollment(1)
  end

  # -- eligibility -----------------------------------------------------------

  def test_eligibility_projects_classification_and_status
    seed_gets(file: "9000001", iens: "1,", fields: Tribal::ELIGIBILITY_FIELDS, text: <<~REPLY.strip)
      [Data]
      9000001^1^1111^13^INDIAN/ALASKA NATIVE
      9000001^1^1112^I^INDIAN/ALASKA NATIVE
    REPLY

    result = Tribal.eligibility(1)

    assert_equal "I", result[:eligibility_status]
    assert_equal "INDIAN/ALASKA NATIVE", result[:eligibility_status_name]
    assert_equal 13, result[:classification_ien]
    assert_equal "INDIAN/ALASKA NATIVE", result[:classification]
  end

  # -- validate (input-transform check via DDR VALIDATOR) --------------------

  def seed_validator(value, internal:, external: nil)
    key = Ddr.validator_param(file: "9000001", iens: "", field: ".07", value: value).to_s
    @mock.seed(:ddr_validator, key, "[FILLER]\n[Data]\n#{internal}\n#{external || internal}")
  end

  def test_validate_accepts_value_passing_the_input_transform
    seed_validator("EX-12345", internal: "EX-12345")

    result = Tribal.validate("EX-12345")

    assert result[:valid]
    assert_equal "EX-12345", result[:internal]
  end

  def test_validate_rejects_value_failing_the_input_transform
    # VAL^DIE returns "^" as the internal value on transform failure
    seed_validator("!!bad!!", internal: "^", external: "")

    result = Tribal.validate("!!bad!!")

    refute result[:valid]
  end

  # -- service unit / tribe table reads --------------------------------------

  def test_service_unit_reads_table_entry_by_ien
    seed_gets(file: "9999999.22", iens: "5,", fields: ".01",
              text: "[Data]\n9999999.22^5^.01^EXAMPLE SERVICE UNIT^EXAMPLE SERVICE UNIT")

    result = Tribal.service_unit(5)

    assert_equal({ ien: 5, name: "EXAMPLE SERVICE UNIT" }, result)
  end

  def test_tribe_info_reads_table_entry_by_ien
    seed_gets(file: "9999999.03", iens: "123,", fields: ".01;.02",
              text: "[Data]\n9999999.03^123^.01^EXAMPLE TRIBE^EXAMPLE TRIBE\n9999999.03^123^.02^997^997")

    result = Tribal.tribe_info(123)

    assert_equal({ ien: 123, name: "EXAMPLE TRIBE", code: "997" }, result)
  end

  def test_tribes_lists_via_b_index
    key = Ddr.lister_param(file: "9999999.03", part: "EX", xref: "B").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n123^EXAMPLE TRIBE\n124^EXAMPLE TRIBE TWO")

    result = Tribal.tribes(part: "EX")

    assert_equal [ { ien: 123, name: "EXAMPLE TRIBE" },
                   { ien: 124, name: "EXAMPLE TRIBE TWO" } ], result
  end

  # -- VFC eligibility (unchanged read path) ---------------------------------

  def test_vfc_eligibility
    result = RpmsRpc::Eligibility.for_patient("1")

    refute_nil result
    assert_equal "V04", result[:code]
  end

  def test_vfc_eligibility_codes
    codes = RpmsRpc::Eligibility.codes

    assert codes.is_a?(Array)
    assert codes.any? { |c| c[:code] == "V04" }
  end
end
