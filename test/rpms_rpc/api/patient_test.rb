# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# Tests for RpmsRpc::Patient symbolic API.
# Engine code calls these methods instead of DataMapper directly.
class PatientTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111223333", age: 45 })
      m.seed(:patient_id_info, "1", {
        ssn: "111223333", dob: Date.new(1980, 1, 15), sex: "M",
        race_code: "I", site_ien: 7819, name: "DOE,JOHN"
      })
      m.seed(:patient_ssn, "111-22-3333", { dfn: 1, name: "DOE,JOHN", ssn: "111-22-3333" })
      m.seed_collection(:patient_list,
        [ { dfn: 1, name: "DOE,JOHN", sex: "M" }, { dfn: 2, name: "SMITH,JANE", sex: "F" } ],
        filter_field: :name)
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # FIND
  # =============================================================================

  def test_find_returns_hash_with_demographics
    result = RpmsRpc::Patient.find(1)

    refute_nil result
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
  end

  def test_find_merges_identifier_fields
    result = RpmsRpc::Patient.find(1)

    # ORWPT ID INFO contributes the site IEN and race code to the merge.
    # Extended demographics (address, city, state, phone, tribal, etc.)
    # have NO known RPC source — the old BHDPTRPC attribution was
    # unverified (see docs/RPC_COVERAGE.md, "BHDPTRPC provenance");
    # a real demographics read path (AG/FileMan) is future work.
    assert_equal "I", result[:race_code]
    assert_equal 7819, result[:site_ien]
  end

  def test_find_returns_nil_for_unknown
    assert_nil RpmsRpc::Patient.find(99999)
  end

  def test_find_returns_nil_for_nil
    assert_nil RpmsRpc::Patient.find(nil)
  end

  # =============================================================================
  # SEARCH
  # =============================================================================

  def test_search_returns_array
    results = RpmsRpc::Patient.search("DOE")

    assert results.is_a?(Array)
    assert_equal 1, results.length
    assert_equal "DOE,JOHN", results.first[:name]
  end

  def test_search_returns_empty_for_no_match
    results = RpmsRpc::Patient.search("ZZZZZ")

    assert_equal [], results
  end

  # =============================================================================
  # FIND BY SSN
  # =============================================================================

  def test_find_by_ssn_returns_hash
    result = RpmsRpc::Patient.find_by_ssn("111-22-3333")

    refute_nil result
    assert_equal 1, result[:dfn]
  end

  def test_find_by_ssn_returns_nil_for_unknown
    assert_nil RpmsRpc::Patient.find_by_ssn("000-00-0000")
  end

  # =============================================================================
  # REGISTER — delegates to the composed RpmsRpc::Registration flow
  # (VAFC VOA ADD PATIENT + DDR FileMan family). The former "BHDPTRPC
  # REGISTER" wire name is retired — it never had a server implementation
  # anywhere (docs/RPC_COVERAGE.md, "BHDPTRPC provenance"). The composed
  # flow itself is covered in test/rpms_rpc/api/registration_test.rb.
  # =============================================================================

  NEW_PATIENT = {
    name: "DEMOPATIENT,NORA", dob: Date.new(1992, 3, 11), sex: "F", ssn: "900012345",
    station_number: "8994", full_icn: "1000000002V654321",
    type: "NON-VETERAN (OTHER)", veteran: "N", service_connected: "NO"
  }.freeze

  def seed_composed_registration(attrs, dfn: "42")
    m = RpmsRpc.client
    m.seed(:voa_add_patient, RpmsRpc::Registration.voa_param(attrs).to_s,
      { status: 1, dfn_or_error: dfn })
    m.seed(:ddr_lock_unlock_node,
      RpmsRpc::DdrFileman.lock_param(node: "^AUPNPAT(#{dfn})").to_s, true)
    m.seed(:ddr_gets_entry_data,
      RpmsRpc::DdrFileman.gets_entry_param(file: "9000001", iens: "#{dfn},", fields: ".01").to_s,
      "[ERROR]")
    m.seed(:ddr_filer, "ADD", "[Data]\n+1,^#{dfn}")
  end

  def test_register_delegates_to_composed_flow_and_returns_dfn
    seed_composed_registration(NEW_PATIENT)

    result = RpmsRpc::Patient.register(NEW_PATIENT)

    assert result[:success]
    assert_equal 42, result[:dfn]
    rpcs = RpmsRpc.client.received_calls.map { |c| c[:rpc] }
    assert_includes rpcs, "VAFC VOA ADD PATIENT"
    assert_includes rpcs, "DDR FILER"
    refute_includes rpcs, "BHDPTRPC REGISTER"
  end

  def test_register_failure_returns_error_symbol_and_message
    RpmsRpc.client.seed(:voa_add_patient, RpmsRpc::Registration.voa_param(NEW_PATIENT).to_s,
      { status: -1, dfn_or_error: "Patient NAME is a required field." })

    result = RpmsRpc::Patient.register(NEW_PATIENT)

    refute result[:success]
    assert_equal :voa_rejected, result[:error]
    assert_match(/required field/, result[:message])
  end

  def test_register_returns_nil_when_broker_gives_no_response
    # Nothing seeded — the mock returns "" (no response) for the VOA call.
    assert_nil RpmsRpc::Patient.register(NEW_PATIENT)
  end
end
