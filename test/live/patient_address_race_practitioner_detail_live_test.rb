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
    dfns = sample_listed_patient_dfns(25)
    populated = 0
    dfns.each do |dfn|
      address = RpmsRpc::Patient.address(dfn)
      next if address.nil?

      line1 = address[:line1].to_s.strip
      city = address[:city].to_s.strip
      populated += 1 unless line1.empty? && city.empty?
    end
    flunk "probed #{dfns.size} listed PATIENT (#2) entries; none had a non-empty address line1 or city" if populated.zero?

    dfn = dfns.first
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
    dfns = sample_listed_patient_dfns(25)
    populated = 0
    dfns.each do |dfn|
      race = RpmsRpc::Patient.race(dfn)
      next if race.nil?

      value = race[:race]
      populated += 1 if value.is_a?(String) && !value.strip.empty?
    end
    flunk "probed #{dfns.size} listed PATIENT (#2) entries; issue #294 asks for a populated race value" if populated.zero?

    dfn = dfns.first
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
    authorized_with_npi = 0
    dea_present = 0
    invalid_release_codes = []
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
      if !internal.empty? && internal != "0" && internal != "1"
        invalid_release_codes << { duz: ien.to_i, internal: internal }
      end
      if internal == "1"
        authorized_count += 1
        expected_npi = external_or_nil(release[:fields]["41.99"])
        assert(detail[:npi] == expected_npi, "NPI release does not match 41.97 internal 1 for DUZ #{ien}")
        authorized_with_npi += 1 unless detail[:npi].nil?
      else
        assert(detail[:npi].nil?, "NPI released although 41.97 internal is not 1 for DUZ #{ien}")
      end

      dea_present += 1 unless detail[:dea_number].nil?

      assert(detail[:dea_expires].nil? || detail[:dea_expires].is_a?(Date))
    end

    unless invalid_release_codes.empty?
      codes = invalid_release_codes.map { |row| row[:internal] }.uniq
      duzs = invalid_release_codes.map { |row| row[:duz] }
      flunk "41.97's code set on this build is not 1/0 and Practitioner.detail's gate must be re-verified; " \
            "offending internal codes: #{codes.inspect}, DUZ: #{duzs.inspect}"
    end

    flunk "probed #{people.size} listed NEW PERSON (#200) entries; none had 41.97 internal \"1\" with a released NPI" if authorized_with_npi.zero?
    flunk "probed #{people.size} listed NEW PERSON (#200) entries; none had a released DEA number" if dea_present.zero?

    puts "listed NEW PERSON entries with 41.97 internal \"1\": #{authorized_count}"
    puts "listed NEW PERSON entries with 41.97 internal \"1\" and a released NPI: #{authorized_with_npi}"
    puts "listed NEW PERSON entries with a released DEA number: #{dea_present}"
  end

  def test_person_class_is_read_for_users_who_hold_one
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 200, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #200 gave no reply"
    refute listed[:error], "DDR LISTER on #200 answered with errors"
    refute_empty listed[:entries], "the build has no NEW PERSON (#200) entry"

    people = listed[:entries].select { |entry| entry[:ien].to_s.match?(/\A\d+\z/) }
    refute_empty people

    lister_errors = 0
    users_with_person_class_rows = 0

    people.each do |entry|
      ien = entry[:ien]
      raw = client.with_context(CONTEXT) do
        RpmsRpc::DdrFileman.lister(file: "200.05", iens: ",#{ien},", fields: "@;.01")
      end
      if raw.nil? || raw[:error]
        lister_errors += 1
        next
      end
      next if raw[:entries].empty?

      users_with_person_class_rows += 1
      detail = RpmsRpc::Practitioner.detail(ien)
      refute_nil detail, "Practitioner.detail(#{ien}) found nothing, but #200 lists it"
      refute_nil detail[:person_class],
                 "8932.1 is a multiple (subfile 200.05) on this build and detail's person_class " \
                 "does not read it (DUZ #{ien.to_i} only, no values)"

      row_externals = person_class_row_externals(raw)
      assert row_externals.include?(detail[:person_class].to_s),
             "person_class does not match the user's 200.05 rows for DUZ #{ien}"
    end

    if lister_errors == people.size
      puts "200.05 DDR LISTER errors: #{lister_errors} of #{people.size} NEW PERSON users probed"
      direct_person_class_count = 0
      people.each do |entry|
        detail = RpmsRpc::Practitioner.detail(entry[:ien])
        refute_nil detail, "Practitioner.detail(#{entry[:ien]}) found nothing, but #200 lists it"
        pc = detail[:person_class]
        direct_person_class_count += 1 if pc.is_a?(String) && !pc.empty?
      end
      if direct_person_class_count.zero?
        flunk "200.05 is not a subfile on this build and no sampled NEW PERSON user had a direct PERSON CLASS " \
              "value (probed #{people.size}); give a test user a (synthetic) PERSON CLASS so the spec can prove person_class"
      end
      people.each do |entry|
        detail = RpmsRpc::Practitioner.detail(entry[:ien])
        refute_nil detail, "Practitioner.detail(#{entry[:ien]}) found nothing, but #200 lists it"
        pc = detail[:person_class]
        assert(pc.nil? || pc.is_a?(String), "person_class must be nil or String for DUZ #{entry[:ien]}")
      end
      puts "NEW PERSON users with a direct PERSON CLASS value: #{direct_person_class_count} of #{people.size} probed"
    else
      puts "NEW PERSON users probed for 200.05: #{people.size}; lister errors: #{lister_errors}; " \
           "users with 200.05 rows: #{users_with_person_class_rows}"
      if users_with_person_class_rows.zero?
        flunk "no sampled NEW PERSON user holds a 200.05 PERSON CLASS row (probed #{people.size}); " \
              "give a test user one (synthetic) so the spec can prove person_class"
      end
    end
  end

  private

  def external_or_nil(field)
    return nil if field.nil?

    value = field[:external]
    value.nil? || value.to_s.empty? ? nil : value.to_s
  end

  def person_class_row_externals(raw)
    raw[:entries].map { |entry| entry[:pieces]&.first.to_s }.reject(&:empty?)
  end

  def sample_listed_patient_dfns(max_entries)
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: PATIENT_FILE, fields: "@;.01", max: max_entries)
    end
    refute_nil listed, "DDR LISTER on #2 gave no reply"
    refute listed[:error]
    refute_empty listed[:entries], "the build has no PATIENT (#2) entry"
    dfns = listed[:entries]
              .select { |entry| entry[:ien].to_s.match?(/\A\d+\z/) }
              .map { |entry| entry[:ien].to_i }
    refute_empty dfns
    dfns
  end

  def absent_patient_dfn
    absent_ien_for(file: PATIENT_FILE)
  end

  def absent_practitioner_duz
    absent_ien_for(file: 200)
  end

  # A FileMan IEN with no entry on file, proven per run through DDR GETS ENTRY
  # DATA — not through the RPC under test.
  def absent_ien_for(file:)
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: file, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #{file} gave no reply"
    refute listed[:error], "DDR LISTER on #{file} answered with errors"
    refute_empty listed[:entries], "the build has no file #{file} entry"
    max_ien = listed[:entries].map { |entry| entry[:ien].to_i }.max
    candidates = (1..4).map { |n| max_ien + (n * 1_000_000) }
    candidates.each do |ien|
      reply = client.with_context(CONTEXT) do
        RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: ".01")
      end
      refute_nil reply, "DDR GETS ENTRY DATA gave no reply for IEN #{ien}"
      return ien if reply[:error]
    end
    flunk "IEN #{candidates.last} is present on file #{file}: pick another absent IEN"
  end
end
