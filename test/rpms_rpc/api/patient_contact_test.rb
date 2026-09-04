# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# Tests for Patient.contact — patient telecom via the registered generic
# FileMan read (DDR GETS ENTRY DATA — GETSC^DDR2: DDR2.m:17-43) against
# PATIENT (#2) fields .131/.132/.134/.133 (^DPT(DFN,.13) pieces 1/2/4/3 —
# PTINFO1^BEHOPTCX: BEHOPTCX.m:34-41; DGRRPSAM.m:84-88; BQIPLADR.m:76).
# No purpose-built registered RPC returns these structured (see the
# Patient.contact comment for the full candidate sweep). Synthetic data.
class PatientContactTest < Minitest::Test
  DFN = 42

  def teardown
    RpmsRpc.reset!
  end

  def contact_key(dfn)
    RpmsRpc::DdrFileman.gets_entry_param(
      file: "2", iens: "#{dfn},", fields: ".131;.132;.134;.133", flags: "IE"
    ).to_s
  end

  def seed_contact(reply)
    RpmsRpc.mock! do |m|
      m.seed(:ddr_gets_entry_data, contact_key(DFN), reply)
    end
  end

  # Default GETSC^DDR2 reply rows: FILE^IENS^FIELD^INTERNAL^EXTERNAL
  # (tag 1: DDR2.m:28-43). Free-text phone/email: internal == external.
  FULL_REPLY = <<~REPLY.chomp
    [Data]
    2^42^.131^555-0101^555-0101
    2^42^.132^555-0102^555-0102
    2^42^.134^555-0103^555-0103
    2^42^.133^demo.patient@example.test^demo.patient@example.test
  REPLY

  def test_contact_returns_all_four_telecom_fields
    seed_contact(FULL_REPLY)

    result = RpmsRpc::Patient.contact(DFN)
    assert_equal(
      { dfn: DFN, phone_home: "555-0101", phone_work: "555-0102",
        phone_cell: "555-0103", email: "demo.patient@example.test" },
      result
    )
  end

  def test_contact_dispatches_ddr_gets_with_patient_file_and_telecom_fields
    seed_contact(FULL_REPLY)
    RpmsRpc::Patient.contact(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_nil call
    assert_equal(
      { "FILE" => "2", "IENS" => "42,", "FIELDS" => ".131;.132;.134;.133", "FLAGS" => "IE" },
      call[:params].first
    )
  end

  def test_contact_returns_nil_values_for_fields_not_on_file
    seed_contact("[Data]\n2^42^.131^555-0101^555-0101")

    result = RpmsRpc::Patient.contact(DFN)
    assert_equal "555-0101", result[:phone_home]
    assert_nil result[:phone_work]
    assert_nil result[:phone_cell]
    assert_nil result[:email]
  end

  def test_contact_returns_nil_on_fileman_error_marker
    seed_contact("[ERROR]")
    assert_nil RpmsRpc::Patient.contact(DFN)
  end

  def test_contact_returns_nil_when_broker_gives_no_response
    RpmsRpc.mock!
    assert_nil RpmsRpc::Patient.contact(DFN)
  end

  def test_contact_rejects_invalid_dfn_without_rpc_call
    RpmsRpc.mock!
    assert_nil RpmsRpc::Patient.contact(nil)
    assert_nil RpmsRpc::Patient.contact(0)
    assert_nil RpmsRpc::Patient.contact("-5")
    assert_empty RpmsRpc.client.received_calls
  end
end
