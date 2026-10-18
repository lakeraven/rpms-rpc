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

  def test_address_returns_nil_for_a_dfn_with_no_patient_entry
    dfn = absent_patient_dfn

    assert_nil RpmsRpc::Patient.address(dfn), "Patient.address(#{dfn}) should find no entry"
  end

  def test_race_returns_the_contract_key_set_for_a_listed_patient
    dfn = listed_patient_dfn
    race = RpmsRpc::Patient.race(dfn)

    refute_nil race, "Patient.race(#{dfn}) gave no reply"
    assert_equal RACE_KEYS, race.keys
    assert_equal dfn, race[:dfn]
    assert(race[:race].nil? || race[:race].is_a?(String))
  end

  def test_race_returns_nil_for_a_dfn_with_no_patient_entry
    dfn = absent_patient_dfn

    assert_nil RpmsRpc::Patient.race(dfn), "Patient.race(#{dfn}) should find no entry"
  end

  def test_detail_returns_nil_for_a_duz_with_no_new_person_entry
    duz = absent_practitioner_duz

    assert_nil RpmsRpc::Practitioner.detail(duz), "Practitioner.detail(#{duz}) should find no entry"
  end

  def test_detail_for_each_listed_user_matches_shape_and_npi_release_rule
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 200, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #200 gave no reply"
    refute listed[:error], "DDR LISTER on #200 answered with errors"
    refute_empty listed[:entries], "the build has no NEW PERSON (#200) entry"

    people = listed[:entries].select { |entry| entry[:ien].to_s.match?(/\A\d+\z/) }
    refute_empty people

    authorized_count = 0
    people.each do |entry|
      ien = entry[:ien]
      detail = RpmsRpc::Practitioner.detail(ien)
      refute_nil detail, "Practitioner.detail(#{ien}) found nothing, but #200 lists it"
      assert_equal DETAIL_KEYS, detail.keys
      assert_equal ien.to_i, detail[:duz]

      release = client.with_context(CONTEXT) do
        RpmsRpc::DdrFileman.gets_entry(file: 200, iens: "#{ien},", fields: "41.97;41.99", flags: "IE")
      end
      refute_nil release
      refute release[:error], "41.97/41.99 read for DUZ #{ien} answered with an error"
      internal = release[:fields].dig("41.97", :internal).to_s
      if internal == "1"
        authorized_count += 1
        expected_npi = external_or_nil(release[:fields]["41.99"])
        assert_equal expected_npi, detail[:npi], "41.97 internal is 1 for DUZ #{ien}"
      else
        assert_nil detail[:npi], "41.97 internal #{internal.inspect} for DUZ #{ien}"
      end

      assert(detail[:dea_expires].nil? || detail[:dea_expires].is_a?(Date))
    end

    puts "listed NEW PERSON entries with 41.97 internal \"1\": #{authorized_count}"
  end

  private

  def external_or_nil(field)
    return nil if field.nil?

    value = field[:external]
    value.nil? || value.to_s.empty? ? nil : value.to_s
  end

  def listed_patient_dfn
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: PATIENT_FILE, fields: "@;.01", max: 5)
    end
    refute_nil listed, "DDR LISTER on #2 gave no reply"
    refute listed[:error]
    refute_empty listed[:entries], "the build has no PATIENT (#2) entry"
    listed[:entries].first[:ien].to_i
  end

  def absent_patient_dfn
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: PATIENT_FILE, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #2 gave no reply"
    refute listed[:error], "DDR LISTER on #2 answered with errors"
    refute_empty listed[:entries], "the build has no PATIENT (#2) entry"
    max_dfn = listed[:entries].map { |entry| entry[:ien].to_i }.max
    max_dfn + 1_000_000
  end

  def absent_practitioner_duz
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 200, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #200 gave no reply"
    refute listed[:error], "DDR LISTER on #200 answered with errors"
    refute_empty listed[:entries], "the build has no NEW PERSON (#200) entry"
    max_duz = listed[:entries].map { |entry| entry[:ien].to_i }.max
    max_duz + 1_000_000
  end
end
