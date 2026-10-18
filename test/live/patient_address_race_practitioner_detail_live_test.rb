# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/ddr_fileman"

# Read-only live specs for Patient.address, Patient.race and Practitioner.detail.
# Shape and key sets only — no demo-value assertions.
class PatientAddressRacePractitionerDetailLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  PATIENT_FILE = "2"
  ADDRESS_KEYS = %i[dfn line1 line2 line3 city state state_ien zip zip4].freeze
  RACE_KEYS = %i[dfn race].freeze
  DETAIL_KEYS = %i[
    duz title service_section provider_class person_class
    npi npi_entry_status dea_number dea_state dea_expires
  ].freeze

  def test_address_returns_the_contract_key_set_for_a_listed_patient
    dfn = listed_patient_dfn
    address = RpmsRpc::Patient.address(dfn)

    refute_nil address, "Patient.address(#{dfn}) gave no reply"
    assert_equal ADDRESS_KEYS, address.keys
    assert_equal dfn, address[:dfn]
  end

  def test_race_returns_the_contract_key_set_for_a_listed_patient
    dfn = listed_patient_dfn
    race = RpmsRpc::Patient.race(dfn)

    refute_nil race, "Patient.race(#{dfn}) gave no reply"
    assert_equal RACE_KEYS, race.keys
    assert_equal dfn, race[:dfn]
    assert(race[:race].nil? || race[:race].is_a?(String))
  end

  def test_detail_for_each_listed_user_matches_shape_and_npi_release_rule
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 200, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #200 gave no reply"
    refute listed[:error], "DDR LISTER on #200 answered with errors: #{listed.inspect}"
    refute_empty listed[:entries], "the build has no NEW PERSON (#200) entry"

    people = listed[:entries].select { |entry| entry[:ien].to_s.match?(/\A\d+\z/) }
    refute_empty people

    people.each do |entry|
      ien = entry[:ien]
      detail = RpmsRpc::Practitioner.detail(ien)
      refute_nil detail, "Practitioner.detail(#{ien}) found nothing, but #200 lists it"
      assert_equal DETAIL_KEYS, detail.keys
      assert_equal ien.to_i, detail[:duz]

      release = client.with_context(CONTEXT) do
        RpmsRpc::DdrFileman.gets_entry(file: 200, iens: "#{ien},", fields: "41.97", flags: "IE")
      end
      refute_nil release
      internal = release[:fields].dig("41.97", :internal).to_s
      if internal == "1"
        assert(detail[:npi].nil? || detail[:npi].is_a?(String))
      else
        assert_nil detail[:npi], "41.97 internal #{internal.inspect} for DUZ #{ien}"
      end

      assert(detail[:dea_expires].nil? || detail[:dea_expires].is_a?(Date))
    end
  end

  private

  def listed_patient_dfn
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: PATIENT_FILE, fields: "@;.01", max: 5)
    end
    refute_nil listed, "DDR LISTER on #2 gave no reply"
    refute listed[:error]
    refute_empty listed[:entries], "the build has no PATIENT (#2) entry"
    listed[:entries].first[:ien].to_i
  end
end
