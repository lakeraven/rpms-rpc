# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization"

# Immunization.forecast reads the vaccines a patient is due for through
# BGOVIMM GET with "F" (GET^BGOVIMM5 -> IMMFORC^BIRPC), the due list
# VueCentric's immunization component shows. The forecast is the
# Immunization package's outside-service call (its ImmServe/TCH forecaster),
# so a build either answers due vaccines, answers none due, or says why it
# produced no forecast. That last answer must reach the host as
# ForecastError with the package's text, never as a vaccine named after the
# error or as an empty due list. Reads only.
class ImmunizationForecastLiveTest < LiveSpec::Test
  runs_as :provider
  DEMO_DFNS = %w[2 3 4 990001].freeze
  STATUSES = [ "due", "past due" ].freeze

  def test_each_demo_patient_has_a_due_list_or_the_package_reason
    DEMO_DFNS.each do |dfn|
      due = RpmsRpc::Immunization.forecast(dfn)
      assert_kind_of Array, due, "DFN #{dfn}: #{due.inspect}"
      due.each do |row|
        refute_empty row[:vaccine], "DFN #{dfn}: #{row.inspect}"
        assert_includes STATUSES, row[:status], "DFN #{dfn}: #{row.inspect}"
        refute_match(/#\d+\z/, row[:vaccine], "DFN #{dfn}: an error row read as a vaccine")
      end
      puts "\n#{role}: DFN #{dfn} -> #{due.size} due"
    rescue RpmsRpc::Immunization::ForecastError => e
      assert_kind_of Integer, e.code, "DFN #{dfn}: the package's error names no code: #{e.message.inspect}"
      refute_empty e.package_message.to_s.strip, "DFN #{dfn}: the package's error has no text"
      puts "\n#{role}: DFN #{dfn} -> no forecast: #{e.message}"
    end
  end

  # The pinned demo build ships forecasting switched off in its Immunization
  # site parameters, so the package says so (BI TABLE ERROR CODE 314). A build
  # that switches it on answers a due list above instead, and this check
  # names the change.
  def test_the_demo_build_says_forecasting_is_disabled
    error = assert_raises(RpmsRpc::Immunization::ForecastError) { RpmsRpc::Immunization.forecast("2") }
    assert_equal 314, error.code, error.message
    assert_equal "Immunization Forecasting disabled (see Site Parameters).", error.package_message
  end

  def test_an_invalid_dfn_answers_nil
    assert_nil RpmsRpc::Immunization.forecast("0")
  end
end
