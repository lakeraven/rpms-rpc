# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/tribal"
require_relative "../captured_replies"

# The Tribal reads on the generic FileMan RPCs (DDR GETS ENTRY DATA, DDR
# LISTER, DDR VALIDATOR) over #9000001 IHS PATIENT, TRIBE #9999999.03,
# SERVICE UNIT #9999999.22 and COMMUNITY #9999999.05. The replies are
# test/fixtures/captured_replies/tribal.yml, captured live as the
# registration persona on the synthetic panel patient DFN 990001, and
# replayed through CiaClient's own reply grammar (rpms-rpc#621, #616).
class TribalTest < Minitest::Test
  Tribal = RpmsRpc::Tribal
  SLUG = "tribal"

  def teardown
    RpmsRpc.reset!
  end

  # Answers the flow's calls with its captured replies and keeps what was sent.
  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_enrollment_projects_the_9000001_tribal_fields
    client = replay("enrollment")

    result = Tribal.enrollment(990_001)

    assert_equal CapturedReplies.flow_calls(SLUG, "enrollment"), sent(client)
    assert_equal({ enrollment_number: "SYN990001", tribe_ien: 803, tribe_name: "INDIAN - TRIBE UNSPECIFIED",
                   tribe_quantum: "1/4", indian_blood_quantum: "1/2", classification_ien: 1,
                   classification: "INDIAN/ALASKA NATIVE", eligibility_status: "D", community: "STONE MESA" }, result)
  end

  # GETS^DIQ answers [ERROR] for an entry not on file.
  def test_enrollment_is_nil_for_a_patient_not_on_file
    replay("enrollment_unknown")

    assert_nil Tribal.enrollment(999_999_999)
  end

  def test_eligibility_projects_the_status_code_its_name_and_the_classification
    replay("eligibility")

    assert_equal({ eligibility_status: "D", eligibility_status_name: "DIRECT ONLY", classification_ien: 1,
                   classification: "INDIAN/ALASKA NATIVE" }, Tribal.eligibility(990_001))
  end

  def test_validate_accepts_a_value_the_input_transform_takes
    replay("validate_valid")

    assert_equal({ valid: true, internal: "SYN12345", external: "SYN12345" }, Tribal.validate("SYN12345"))
  end

  # VAL^DIE answers "^" as the internal value when the transform refuses
  # (.07 takes 1-16 characters).
  def test_validate_refuses_a_value_the_input_transform_does_not_take
    replay("validate_invalid")

    refute Tribal.validate("X" * 40)[:valid]
  end

  def test_service_unit_reads_the_table_entry_by_ien
    replay("service_unit")

    assert_equal({ ien: 1, name: "NON SERVICE UNIT" }, Tribal.service_unit(1))
  end

  def test_tribe_info_reads_the_name_and_the_code
    replay("tribe_info")

    assert_equal({ ien: 697, name: "KWETHLUK, INC.", code: "815" }, Tribal.tribe_info(697))
  end

  def test_tribes_list_by_the_b_index
    client = replay("tribes")

    assert_equal [ { ien: 697, name: "KWETHLUK, INC." }, { ien: 532, name: "KWETHLUK, ORGANIZED VILLAGE OF KWETHLUK" } ],
                 Tribal.tribes(part: "KWETH")
    assert_equal CapturedReplies.flow_calls(SLUG, "tribes"), sent(client)
  end

  # A community name repeats across states, so the county and state ride along.
  def test_communities_list_by_the_b_index_with_county_and_state
    replay("communities")

    assert_equal [ { ien: 10_663, name: "STONEHAM", county: "MIDDLESEX", state: "MASSACHUSETTS" } ],
                 Tribal.communities(part: "STONEHAM")
  end
end
