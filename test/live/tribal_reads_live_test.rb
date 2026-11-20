# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/ddr_fileman"

# The Tribal reads the pilot's registration slice uses, each on a generic
# FileMan RPC (DDR GETS ENTRY DATA, DDR LISTER, DDR VALIDATOR) over IHS
# PATIENT (#9000001), TRIBE (#9999999.03), SERVICE UNIT (#9999999.22) and
# COMMUNITY (#9999999.05), as the front desk clerk (rpms-rpc#616).
# Enrollment on a panel patient is tribal_panel_enrollment_live_test.rb.
# Reads only.
class TribalReadsLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk

  DFN = 990_001 # ALPHA,CASEY, a synthetic panel patient

  def test_eligibility_answers_the_status_code_and_the_classification
    eligibility = RpmsRpc::Tribal.eligibility(DFN)

    refute_nil eligibility, "Tribal.eligibility(#{DFN}) gave no answer"
    assert_equal "INDIAN/ALASKA NATIVE", eligibility[:classification]
    assert_kind_of Integer, eligibility[:classification_ien]
    assert_includes %w[C D I P], eligibility[:eligibility_status], "#9000001 1112 is a set of codes"
    refute_empty eligibility[:eligibility_status_name].to_s
  end

  def test_an_unknown_patient_has_no_enrollment
    assert_nil RpmsRpc::Tribal.enrollment(999_999_999)
  end

  def test_tribes_list_by_name_and_each_reads_back_by_ien
    tribes = RpmsRpc::Tribal.tribes(part: "KWETH")

    refute_empty tribes, "no tribe starting KWETH on the B index"
    tribes.each { |tribe| assert tribe[:name].start_with?("KWETH"), tribe.inspect }
    first = tribes.first
    info = RpmsRpc::Tribal.tribe_info(first[:ien])
    assert_equal first[:ien], info[:ien]
    assert_equal first[:name], info[:name]
    assert_match(/\A\d{3}\z/, info[:code].to_s, "TRIBE .02 is the three-digit code")
  end

  def test_communities_list_by_name_with_county_and_state
    communities = RpmsRpc::Tribal.communities(part: "STONEHAM")

    refute_empty communities
    communities.each do |community|
      assert community[:name].start_with?("STONEHAM"), community.inspect
      assert community[:ien].positive?
    end
    assert(communities.all? { |c| !c[:county].to_s.empty? && !c[:state].to_s.empty? }, communities.inspect)
  end

  def test_a_service_unit_reads_by_ien
    unit = RpmsRpc::Tribal.service_unit(first_service_unit_ien)

    refute_nil unit
    refute_empty unit[:name].to_s
  end

  def test_validate_accepts_an_enrollment_number_and_refuses_one_too_long
    accepted = RpmsRpc::Tribal.validate("SYN12345")
    assert_equal({ valid: true, internal: "SYN12345", external: "SYN12345" }, accepted)

    refute RpmsRpc::Tribal.validate("X" * 40)[:valid], "#9000001 .07 takes 1-16 characters"
  end

  private

  def first_service_unit_ien
    listed = RpmsRpc::DdrFileman.lister(file: RpmsRpc::Tribal::SERVICE_UNIT_FILE, fields: "@;.01", max: "1")
    ien = Array(listed && listed[:entries]).first&.dig(:ien).to_i
    flunk "SERVICE UNIT (#9999999.22) has no entry on this build: #{listed.inspect}" unless ien.positive?
    ien
  end
end
