# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/registration_parameters"
require_relative "../captured_replies"

# RegistrationParameters.for_facility on the build's own replies
# (test/fixtures/captured_replies/registration-parameters.yml), recorded as
# the registration persona on a throwaway container and replayed through
# CiaClient. The live spec (test/live/registration_parameters_live_test.rb)
# files values and reads them back; this pins how the replies are read.
class RegistrationParametersTest < Minitest::Test
  SLUG = "registration-parameters"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_the_divisions_switches_and_mandatory_fields_are_read_as_rpms_holds_them
    client = replay(CapturedReplies.flow_script(SLUG, "division"))

    read = RpmsRpc::RegistrationParameters.for_facility(7819)

    assert_equal 7819, read[:facility]
    assert read[:on_file]
    # ^AGFAC(7819,0) on the build: pieces 2-6 N, 7 (field 6, directions) Y,
    # 8-12 N, 21 (field 20) Y, 28-29 (fields 27, 28) Y; field 2101 unset.
    assert_equal false, read[:switches][:blood_quantum]
    assert_equal true, read[:switches][:directions_to_home]
    assert_equal false, read[:switches][:next_of_kin]
    assert_equal false, read[:switches][:limited_dob_editing]
    assert_equal true, read[:switches][:official_registering_facility]
    assert_equal true, read[:switches][:display_homeless]
    assert_nil read[:switches][:insurer_sequencing_required]
    assert_equal [
      { file: "2", field: "ETHNICITY INFORMATION", required: true },
      { file: "2", field: "RACE", required: true },
      { file: "9000001", field: "ASSIGN BENEFITS OBTAINED DATE", required: true },
      { file: "9000001", field: "PREFERRED LANGUAGE", required: true },
      { file: "9000001", field: "PRIMARY LANGUAGE", required: false },
      { file: "9000001", field: "RELEASE OF INFORMATION", required: true }
    ], read[:mandatory_fields]
    assert_equal CapturedReplies.flow_calls(SLUG, "division").map(&:first), client.rpcs_called - [ :create_context ]
  end

  def test_required_follows_isreq_a_field_listed_no_or_not_listed_is_not_required
    replay(CapturedReplies.flow_script(SLUG, "division"))
    read = RpmsRpc::RegistrationParameters.for_facility(7819)

    assert RpmsRpc::RegistrationParameters.required?(read, "9000001", "PREFERRED LANGUAGE")
    refute RpmsRpc::RegistrationParameters.required?(read, "9000001", "PRIMARY LANGUAGE")
    refute RpmsRpc::RegistrationParameters.required?(read, "2", "PHONE NUMBER [RESIDENCE]")
    refute RpmsRpc::RegistrationParameters.required?(read, 2, "RACE ") # labels match exactly
    assert RpmsRpc::RegistrationParameters.required?(read, 2, "RACE")
  end

  def test_a_facility_with_no_entry_is_not_on_file_and_reads_nothing_more
    client = replay(CapturedReplies.flow_script(SLUG, "not_on_file"))

    read = RpmsRpc::RegistrationParameters.for_facility(999_999)

    refute read[:on_file]
    assert(read[:switches].values.all?(&:nil?))
    assert_empty read[:mandatory_fields]
    assert_equal [ "DDR LISTER" ], client.rpcs_called - [ :create_context ]
  end

  # The build answers a multiple under a missing parent with an empty [Data]
  # list, so on_file is decided from the file's own list first, never from
  # an empty multiple.
  def test_an_empty_multiple_under_a_missing_parent_is_a_list_not_a_refusal
    raw = CapturedReplies.raw(SLUG, "mandatory_files_of_absent_facility")
    assert_includes raw, "[Data]"
  end

  def test_a_refused_switch_read_raises_and_is_never_read_as_nothing_set
    script = CapturedReplies.flow_script(SLUG, "division")
    script["DDR GETS ENTRY DATA"] = [ CapturedReplies.raw(SLUG, "switches_of_absent_facility") ]
    replay(script)

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::RegistrationParameters.for_facility(7819) }
    assert_match(/DDR GETS ENTRY DATA refused #9009061 7819/, error.message)
  end

  def test_a_facility_that_is_not_a_positive_integer_is_refused_before_anything_is_sent
    client = replay({})

    [ 0, -1, "7819;", "" ].each do |bad|
      assert_raises(ArgumentError) { RpmsRpc::RegistrationParameters.for_facility(bad) }
    end
    assert_empty client.calls
  end
end
