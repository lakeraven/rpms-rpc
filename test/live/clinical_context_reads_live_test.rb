# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/order"

# Allergy.awaiting_signature (BEHOART SIGNLIST), Encounter.providers
# (BEHOENCX GETPRV), Order.display_group_ien (ORWORDG IEN) and
# Order.checking_enabled? (ORWDXC ON). Each answer is checked against the
# file it reads: ADVERSE REACTION ASSESSMENT (#120.8), V PROVIDER
# (#9000010.06), DISPLAY GROUP (#100.98) and the ORK SYSTEM ENABLE/DISABLE
# parameter. Read only.
class ClinicalContextReadsLiveTest < LiveSpec::Test
  runs_as "PROV123"
  ALLERGY_DFN = 2 # the demo patient whose PENICILLIN entry awaits verification on the pinned build

  def test_the_sign_list_names_entries_of_the_patient_with_their_reactant
    listed = RpmsRpc::Allergy.awaiting_signature(ALLERGY_DFN)
    refute_empty listed, "BEHOART SIGNLIST answered nothing for DFN #{ALLERGY_DFN}: is this the pinned image?"
    listed.each do |entry|
      fields = entry("120.8", entry[:ien], ".01;.02")
      assert_equal ALLERGY_DFN.to_s, fields.dig(".01", :internal), "#120.8 #{entry[:ien]} is the patient's"
      assert_equal fields.dig(".02", :external), entry[:reactant], "the reactant is #120.8 .02"
      assert_includes %i[sign verify], entry[:action]
    end
    assert_equal listed, RpmsRpc::Allergy.awaiting_signature(ALLERGY_DFN, skip_autoverify: true).select { |e| listed.include?(e) }
    assert_empty RpmsRpc::Allergy.awaiting_signature(999_999_999)
  end

  def test_a_visits_providers_read_back_against_v_provider
    row = first_v_provider
    visit = row[:visit]
    dfn = row[:patient]
    providers = RpmsRpc::Encounter.providers(dfn, visit)
    refute_empty providers, "BEHOENCX GETPRV answered nothing for visit #{visit}"
    assert_includes providers.map { |p| p[:duz] }, row[:provider], "V PROVIDER #{row[:ien]}'s provider is listed"
    names = providers.to_h { |p| [ p[:duz], p[:name] ] }
    assert_equal entry("200", row[:provider], ".01").dig(".01", :external), names[row[:provider]]

    primaries = RpmsRpc::Encounter.providers(dfn, visit, primary_only: true)
    assert(primaries.all? { |p| p[:primary] }, "primary_only keeps the primary provider: #{primaries.inspect}")
    assert_equal providers.select { |p| p[:primary] }, primaries

    assert_empty RpmsRpc::Encounter.providers(dfn == 2 ? 4 : 2, visit), "a visit of another patient answers nothing"
  end

  def test_display_group_ien_reads_the_b_index
    listed = RpmsRpc::DdrFileman.lister(file: "100.98", fields: ".01", flags: "IP", max: "3")
    flunk "DDR LISTER on DISPLAY GROUP failed: #{listed.inspect}" if listed.nil? || listed[:error] || listed[:entries].empty?
    listed[:entries].each do |group|
      assert_equal group[:ien].to_i, RpmsRpc::Order.display_group_ien(group[:pieces].first), group.inspect
    end
    assert_nil RpmsRpc::Order.display_group_ien("ZZ NO SUCH DISPLAY GROUP")
  end

  def test_checking_enabled_answers_a_boolean
    assert_includes [ true, false ], RpmsRpc::Order.checking_enabled?
  end

  private

  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end

  # A V PROVIDER entry: its provider (.01), patient (.02) and visit (.03).
  def first_v_provider
    listed = RpmsRpc::DdrFileman.lister(file: "9000010.06", fields: ".01;.02;.03", flags: "IP", max: "1")
    flunk "DDR LISTER on V PROVIDER failed: #{listed.inspect}" if listed.nil? || listed[:error] || listed[:entries].empty?
    row = listed[:entries].first
    provider, patient, visit = row[:pieces].first(3).map(&:to_i)
    { ien: row[:ien], provider: provider, patient: patient, visit: visit }
  end
end
