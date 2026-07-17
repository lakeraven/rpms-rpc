# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "rpms_rpc/version"
require "rpms_rpc/cia_client"
require "rpms_rpc/api/medication"

# Live CPRS-style read workflows against the local WorldVistA VEHU container
# (docs/research/docker-vista-setup.md). These tests are read-only and touch
# only the synthetic patients bundled with the VEHU image; assertions are
# structural (shapes and types), so no patient values are persisted or
# printed on failure beyond synthetic-row contents.
#
# Opt in explicitly:
#   VEHU_INTEGRATION=1 bundle exec rake test
#
# Without the env var — or when the container is not reachable — every test
# skips, keeping the default suite hermetic.
class VehuCprsWorkflowsTest < Minitest::Test
  HOST = ENV.fetch("VEHU_HOST", "127.0.0.1")
  PORT = ENV.fetch("VEHU_PORT", "9430").to_i
  ACCESS = ENV.fetch("VEHU_ACCESS_CODE", "PRO1234")
  VERIFY = ENV.fetch("VEHU_VERIFY_CODE", "PRO1234!!")
  CONTEXT = "OR CPRS GUI CHART"

  # Bundled synthetic patients (docs/research/docker-vista-setup.md):
  # 100022 has demographics, allergies, vitals, consults, and medications;
  # 100001 has problem-list entries.
  PROBE_DFN = ENV.fetch("VEHU_DFN", "100022")
  PROBLEMS_DFN = ENV.fetch("VEHU_PROBLEMS_DFN", "100001")

  def setup
    skip "set VEHU_INTEGRATION=1 to run live VEHU tests" unless ENV["VEHU_INTEGRATION"] == "1"
    skip "VEHU container not reachable at #{HOST}:#{PORT}" unless vehu_reachable?

    @original_client = VistaRpc.configuration.client
    @client = RpmsRpc::CiaClient.new(host: HOST, port: PORT)
    @client.connect
    auth = @client.authenticate(ACCESS, VERIFY)
    flunk "VEHU authentication failed" unless auth[:success]

    @duz = auth[:duz]
    @client.create_context(CONTEXT)
    VistaRpc.configure { |c| c.client = @client }
  end

  def teardown
    @client&.disconnect
    VistaRpc.configure { |c| c.client = @original_client } if defined?(@original_client)
  end

  # -- authentication ---------------------------------------------------------

  def test_authentication_yields_a_positive_duz
    assert_operator @duz.to_i, :>, 0
  end

  # -- patient selection + demographics ---------------------------------------

  def test_patient_search_returns_dfn_and_name_rows
    results = VistaRpc::Patient.search("A")

    refute_empty results
    results.first(3).each do |row|
      assert_operator row[:dfn].to_i, :>, 0
      refute_empty row[:name].to_s
    end
  end

  def test_patient_demographics_round_trip
    patient = VistaRpc::Patient.find(PROBE_DFN)

    refute_nil patient
    refute_empty patient[:name].to_s
    assert_includes %w[M F], patient[:sex].to_s
    assert_kind_of Date, patient[:dob]
    refute_empty patient[:ssn].to_s
  end

  # -- clinical reads ----------------------------------------------------------

  def test_problem_list_rows_match_the_mapping_shape
    problems = VistaRpc::Problem.for_patient(PROBLEMS_DFN)

    refute_empty problems
    problems.each do |p|
      assert_operator p[:ien].to_i, :>, 0
      refute_empty p[:description].to_s
      assert_includes %w[A I], p[:status].to_s
    end
  end

  def test_allergy_rows_match_the_mapping_shape
    allergies = VistaRpc::Allergy.for_patient(PROBE_DFN)

    refute_empty allergies
    allergies.each do |a|
      assert_kind_of Integer, a[:allergy_ien]
      assert_operator a[:allergy_ien], :>, 0
      refute_empty a[:allergen].to_s
    end
  end

  def test_vitals_rows_match_the_mapping_shape
    vitals = VistaRpc::Vital.for_patient(PROBE_DFN)

    refute_empty vitals
    vitals.each do |v|
      refute_empty v[:type].to_s
      refute_empty v[:value].to_s
    end
  end

  def test_medication_profile_returns_rows_with_required_date_params
    meds = RpmsRpc::Medication.for_patient(PROBE_DFN)

    refute_empty meds
    meds.each do |m|
      refute_empty m[:ien].to_s
      refute_empty m[:drug_name].to_s
    end
  end

  # -- order/consult read workflow ---------------------------------------------

  def test_consult_list_and_detail_round_trip
    consults = RpmsRpc::DataMapper[:consult_list].fetch_many(PROBE_DFN)

    refute_empty consults
    first = consults.first
    assert_operator first[:ien], :>, 0
    refute_empty first[:status].to_s

    detail = RpmsRpc::DataMapper[:consult_detail].fetch_one(first[:ien].to_s)
    refute_nil detail
    assert_equal PROBE_DFN.to_i, detail[:patient_dfn]
  end

  private

  def vehu_reachable?
    Socket.tcp(HOST, PORT, connect_timeout: 2, &:close)
    true
  rescue StandardError
    false
  end
end
