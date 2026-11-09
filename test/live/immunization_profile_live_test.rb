# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization"
require "rpms_rpc/api/ddr_fileman"

# Immunization.text_summary reads the patient's Immunization Profile through
# BGOVIMM PROFILE (PROFILE^BGOVIMM2 -> IMMPROF^BIRPC), the text VueCentric's
# immunization component shows (#656). It used to send the DFN to BEHOCIR
# GETTXT, a SNOMED CT lookup that answered "^" for every patient.
#
# The spec reads only; it files nothing. For each demo patient the profile is
# text, never "^", and a patient who is not in the Immunization Register
# (file 9002084, read with DDR GETS ENTRY DATA) gets the package's message
# saying so. A package error raises; the captured error reply is pinned in
# test/rpms_rpc/api/immunization_test.rb.
class ImmunizationProfileLiveTest < LiveSpec::Test
  DEMO_DFNS = %w[2 3 4 990001].freeze
  NOT_IN_REGISTER = "This patient is not in the Immunization Register."

  def test_each_demo_patient_has_profile_text_not_a_snomed_lookup
    DEMO_DFNS.each do |dfn|
      text = profile_or_package_error(dfn)
      next if text.nil?

      refute_empty text.strip, "DFN #{dfn}: an empty profile"
      refute_equal "^", text.strip, "DFN #{dfn}: the SNOMED lookup's empty answer, not a profile"
      if registered?(dfn)
        refute text.start_with?(NOT_IN_REGISTER), "DFN #{dfn} is in the register, and the profile says it is not"
      else
        assert text.start_with?(NOT_IN_REGISTER), "DFN #{dfn} is not in the register: #{text.inspect}"
      end
      puts "\n#{persona}: DFN #{dfn} -> #{text.lines.first.to_s.strip.inspect} (#{text.lines.size} lines)"
    end
  end

  def test_an_invalid_dfn_answers_nil
    assert_nil RpmsRpc::Immunization.text_summary("0")
  end

  private

  # The profile, or nil when the package reported an error (raised as
  # RpcError, never returned as text). A registered patient on a build with
  # no ImmServe forecaster gets error 307.
  def profile_or_package_error(dfn)
    RpmsRpc::Immunization.text_summary(dfn)
  rescue RpmsRpc::Client::RpcError => e
    flunk "DFN #{dfn}: BGOVIMM PROFILE was refused: #{e.message}" if e.is_a?(RpmsRpc::Client::RpcRefusedError)
    assert registered?(dfn), "DFN #{dfn} is not in the register, so the package should answer its message, not #{e.message.inspect}"
    puts "\n#{persona}: DFN #{dfn} -> package error #{e.message.inspect}"
    nil
  end

  # Whether the patient has an entry in BI PATIENT (9002084, DINUM to DFN).
  def registered?(dfn)
    entry = RpmsRpc::DdrFileman.gets_entry(file: "9002084", iens: "#{dfn},", fields: ".01", flags: "I")
    !entry.nil? && !entry[:error] && !entry[:fields].dig(".01", :internal).to_s.empty?
  end
end
