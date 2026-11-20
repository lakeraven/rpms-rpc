# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require_relative "captured_replies"

# DataMapper's fetch_one, fetch_many, fetch_scalar and fetch_text through the
# configured client. The replies are test/fixtures/captured_replies/data-mapper-fetch.yml,
# captured live as the clinician PROVIDER,TEST and replayed through CiaClient's
# own reply grammar (rpms-rpc#623).
class RpmsRpc::FetchApiTest < Minitest::Test
  SLUG = "data-mapper-fetch"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # -- method-style lookup ---------------------------------------------------

  def test_method_lookup_returns_mapping
    mapping = RpmsRpc::DataMapper.patient_select
    assert_equal "ORWPT SELECT", mapping.rpc_name
  end

  def test_method_lookup_for_all_mappings
    %i[
      patient_select patient_id_info patient_list patient_ssn
      allergy_list problem_list vitals medication_list
      practitioner_info practitioner_list
    ].each do |name|
      assert_respond_to RpmsRpc::DataMapper, name, "DataMapper should respond to .#{name}"
    end
  end

  def test_method_lookup_raises_for_unknown
    assert_raises(NoMethodError) { RpmsRpc::DataMapper.nonexistent_mapping }
  end

  # -- fetch_one -------------------------------------------------------------

  # ORWPT SELECT answers NAME^SEX^DOB^SSN^...^AGE for the seed patient USER,TEST.
  def test_fetch_one_calls_rpc_and_parses
    client = replay("select")

    result = RpmsRpc::DataMapper.patient_select.fetch_one("2", extras: { dfn: 2 })

    assert_equal({ name: "USER,TEST", sex: "M", dob: Date.new(1985, 5, 5), ssn: nil, age: 41, dfn: 2 }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "select"), sent(client)
  end

  # For a DFN not on file ORWPT SELECT answers "-1^^^^^Patient is unknown to
  # CPRS.", which is no patient.
  def test_fetch_one_returns_nil_for_a_patient_not_on_file
    client = replay("select_unknown")

    assert_nil RpmsRpc::DataMapper.patient_select.fetch_one("999999999")
    assert_equal CapturedReplies.flow_calls(SLUG, "select_unknown"), sent(client)
  end

  # -- fetch_many ------------------------------------------------------------

  # ORQQAL LIST answers IEN^ALLERGEN^SEVERITY^SIGNS; USER,TEST has one allergy.
  def test_fetch_many_parses_array
    client = replay("allergies")

    results = RpmsRpc::DataMapper.allergy_list.fetch_many("2")

    assert_equal [ { ien: "1", allergen: "PENICILLIN", severity: nil, signs: "HIVES" } ], results
    assert_equal CapturedReplies.flow_calls(SLUG, "allergies"), sent(client)
  end

  # ORWPT LIST ALL answers one page of the name index starting AT the text,
  # not the names that begin with it: from DEMO it runs past every DEMO name.
  def test_fetch_many_reads_a_page_of_the_name_index
    client = replay("list_from_demo")

    results = RpmsRpc::DataMapper.patient_list.fetch_many("DEMO", "1")

    assert_equal 44, results.size
    assert_equal({ dfn: 4, name: "DEMO,PATIENT ONE" }, results.first)
    assert_equal({ dfn: 990_025, name: "YANKEE,MORGAN" }, results.last)
    assert(results.all? { |row| row[:dfn].is_a?(Integer) && row[:dfn].positive? })
    assert_equal CapturedReplies.flow_calls(SLUG, "list_from_demo"), sent(client)
  end

  # After the last name the page is empty.
  def test_fetch_many_returns_empty_for_no_data
    client = replay("list_past_the_end")

    assert_equal [], RpmsRpc::DataMapper.patient_list.fetch_many("ZZZZZ", "1")
    assert_equal CapturedReplies.flow_calls(SLUG, "list_past_the_end"), sent(client)
  end

  # -- fetch_scalar ----------------------------------------------------------

  # ORWPT SELCHK answers "0" for a patient whose record is not sensitive.
  def test_fetch_scalar_parses_value
    client = replay("sensitive")

    assert_equal false, RpmsRpc::DataMapper.patient_sensitive.fetch_scalar("2")
    assert_equal CapturedReplies.flow_calls(SLUG, "sensitive"), sent(client)
  end

  # -- fetch_text ------------------------------------------------------------

  # ORWRP REPORT TEXT answers the report as lines, and fetch_text joins them.
  # The report asked for (HSTYPE 999) is not on file, so the text is the
  # fault the build prints.
  def test_fetch_text_joins_lines
    client = replay("report_text")

    lines = RpmsRpc::DataMapper.report_text.fetch_text("4", "IHS", "999", "", "", "", "").split("\n", -1)

    assert_equal 4, lines.size
    assert_equal "An error was encountered generating this report.", lines[0]
    assert_match(/\AThe error was: HEADER\+5\^APCHS0, /, lines[1])
    assert_equal "", lines[2]
    assert_match(/\A\*\*\* END \* CONFIDENTIAL PATIENT INFORMATION/, lines[3])
    assert_equal CapturedReplies.flow_calls(SLUG, "report_text"), sent(client)
  end

  # -- fetch raises when not configured --------------------------------------

  def test_fetch_raises_when_not_configured
    assert_raises(RpmsRpc::NotConfiguredError) do
      RpmsRpc::DataMapper.patient_select.fetch_one("1")
    end
  end
end
