# frozen_string_literal: true

require "rpms_rpc/api/immunization"
require "rpms_rpc/api/ddr_fileman"

# The checks the CIA and BMX immunization-profile live specs share
# (test/live/immunization_profile_live_test.rb, test/live/bmx/...): each
# demo patient's profile is text, never the SNOMED lookup's "^", and a patient
# not in the Immunization Register gets the package's message saying so.
module ImmunizationProfileChecks
  DEMO_DFNS = %w[2 3 4 990001].freeze
  NOT_IN_REGISTER = "This patient is not in the Immunization Register."

  def test_each_demo_patient_has_profile_text_not_a_snomed_lookup
    DEMO_DFNS.each do |dfn|
      text = profile_or_package_error(dfn)
      next if text.nil?

      refute_empty text.strip, "DFN #{dfn}: an empty profile"
      refute_equal "^", text.strip, "DFN #{dfn}: the SNOMED lookup's empty answer, not a profile"
      case registered?(dfn)
      when true then refute text.start_with?(NOT_IN_REGISTER), "DFN #{dfn} is in the register, and the profile says it is not"
      when false then assert text.start_with?(NOT_IN_REGISTER), "DFN #{dfn} is not in the register: #{text.inspect}"
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
    # Only the package's own error (IMMERR^BGOVIMM: -1082^text) is an answer;
    # a refusal, an M error or a reply with no end line fails the spec.
    raise unless e.message.include?("BGOVIMM PROFILE: -1082^")

    refute_equal false, registered?(dfn), "DFN #{dfn} is not in the register, so the package should answer its message, not #{e.message.inspect}"
    puts "\n#{persona}: DFN #{dfn} -> package error #{e.message.inspect}"
    nil
  end

  # Whether the patient has an entry in BI PATIENT (9002084, DINUM to DFN),
  # or nil when this broker line cannot read it (see the BMX spec).
  def registered?(dfn)
    entry = RpmsRpc::DdrFileman.gets_entry(file: "9002084", iens: "#{dfn},", fields: ".01", flags: "I")
    !entry.nil? && !entry[:error] && !entry[:fields].dig(".01", :internal).to_s.empty?
  end
end
