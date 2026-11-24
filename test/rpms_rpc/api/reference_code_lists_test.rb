# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/taxonomy"
require_relative "../captured_replies"

# The RPMS local code lists lakeraven-ehr serves as code systems and value
# sets (rpms-rpc#917, #918): measurement types, exam types and taxonomies,
# read through DDR LISTER. The replies are the build's
# (test/fixtures/captured_replies/reference-code-lists.yml), recorded as
# flows as the provider test role and replayed through CiaClient; each test
# checks the gem sent exactly the recorded calls.
class ReferenceCodeListsTest < Minitest::Test
  SLUG = "reference-code-lists"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def assert_sent_the_recorded_calls(flow)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
    assert_equal CapturedReplies.flow_calls(SLUG, flow), sent
  end

  # The build has 83 measurement types; 2 are inactive and still listed.
  def test_measurement_types_list_every_type_with_its_code_and_flag_the_inactive
    replay("measurement_types")

    types = RpmsRpc::Measurement.types

    assert_equal 83, types.size
    assert_equal({ ien: 2, code: "02", name: "WEIGHT", abbreviation: "WT", inactive: false }, types.find { |t| t[:ien] == 2 })
    assert_equal 2, types.count { |t| t[:inactive] }
    assert(types.all? { |t| t[:code].match?(/\A\d+\z/) && !t[:name].empty? }, "every type has a code and a name")
    assert_sent_the_recorded_calls("measurement_types")
  end

  # 51 exams, 25 of them inactive (ABDOMEN EXAM among them).
  def test_exam_types_list_every_exam_with_its_code_and_flag_the_inactive
    replay("exam_types")

    types = RpmsRpc::ExamComponent.types

    assert_equal 51, types.size
    assert_equal({ ien: 9, code: "09", name: "ABDOMEN EXAM", inactive: true }, types.find { |t| t[:ien] == 9 })
    assert_equal 25, types.count { |t| t[:inactive] }
    assert_sent_the_recorded_calls("exam_types")
  end

  # An ICD taxonomy keeps each range as a range, with its coding system,
  # less the trailing blank FileMan stores on ICD values.
  def test_a_code_taxonomy_keeps_its_ranges_and_coding_systems
    replay("members_code")

    taxonomy = RpmsRpc::Taxonomy.members("SURVEILLANCE DIABETES")

    assert_equal({ name: "SURVEILLANCE DIABETES", kind: :code, file: "80",
                   members: [ { low: "250.00", high: "250.93", code_system: "ICD-9-CM" },
                              { low: "E10.10", high: "E13.9", code_system: "ICD-10-CM" } ] }, taxonomy)
    assert_sent_the_recorded_calls("members_code")
  end

  # A lab taxonomy's members are LABORATORY TEST (#60) entries.
  def test_a_lab_taxonomy_lists_its_lab_tests
    replay("members_lab")

    taxonomy = RpmsRpc::Taxonomy.members("APCP PAP SMEAR TESTS")

    assert_equal({ name: "APCP PAP SMEAR TESTS", kind: :lab, file: "60", members: [ { ien: 643, name: "PAP SMEAR" } ] }, taxonomy)
    assert_sent_the_recorded_calls("members_lab")
  end

  def test_an_unknown_taxonomy_is_not_found_not_empty
    replay("members_unknown")

    error = assert_raises(RpmsRpc::Taxonomy::NotFoundError) { RpmsRpc::Taxonomy.members("NO SUCH TAXONOMY") }
    assert_equal 'no taxonomy is named "NO SUCH TAXONOMY"', error.message
    assert_sent_the_recorded_calls("members_unknown")
  end

  # LISTER answers MORE^<last value> while there is more; list_all sends it
  # back as FROM until a page has no MORE. 42 SURVEILLANCE taxonomies, 20 a
  # page: three pages, nothing listed twice.
  def test_list_all_follows_listers_continuation_to_the_end
    replay("paged")

    entries = RpmsRpc::DdrFileman.list_all(file: "9002226", fields: "@;.01", part: "SURVEILLANCE", page: 20)

    assert_equal 42, entries.size
    assert_equal entries.size, entries.map { |e| e[:ien] }.uniq.size
    assert(entries.all? { |e| e[:pieces].first.start_with?("SURVEILLANCE") })
    assert_sent_the_recorded_calls("paged")
  end

  # LISTER's error reply for a file the build does not have is a failed
  # read, never an empty list.
  def test_a_lister_error_raises_rather_than_listing_nothing
    replay("no_such_file")

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::DdrFileman.list_all(file: "9999999.999", fields: "@;.01") }
    assert_equal "DDR LISTER could not list #9999999.999", error.message
    assert_sent_the_recorded_calls("no_such_file")
  end
end
