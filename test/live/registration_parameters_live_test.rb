# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration_parameters"
require "rpms_rpc/api/ddr_fileman"

# RegistrationParameters on a real build: the signed-on division's
# REGISTRATION PARAMETERS (#9009061) switches and site-specific mandatory
# fields, as AG's screens read them (lakeraven-ehr#980, #981). Each value is
# filed first through DDR FILER and read back, so the read is proven against a
# stored value and not only the build's own; everything filed is put back.
class RegistrationParametersLiveTest < LiveSpec::Test
  writes!

  FILE = RpmsRpc::RegistrationParameters::FILE

  def facility = client.division[:ien]

  def test_the_divisions_switches_read_back_as_filed
    original = RpmsRpc::RegistrationParameters.for_facility(facility)
    assert original[:on_file], "the build's division #{facility} has a REGISTRATION PARAMETERS entry"
    flipped = original[:switches][:next_of_kin] ? "N" : "Y"

    begin
      file_top("7" => flipped, "12" => "Y", "2101" => "1")
      switches = RpmsRpc::RegistrationParameters.for_facility(facility)[:switches]
      assert_equal flipped == "Y", switches[:next_of_kin]
      assert_equal true, switches[:limited_dob_editing]
      assert_equal true, switches[:insurer_sequencing_required]
    ensure
      file_top("7" => code(original[:switches][:next_of_kin]), "12" => code(original[:switches][:limited_dob_editing]),
               "2101" => code(original[:switches][:insurer_sequencing_required], yes: "1", no: "0"))
    end
    assert_equal original, RpmsRpc::RegistrationParameters.for_facility(facility), "the switches are put back"
  end

  def test_a_mandatory_field_the_site_adds_reads_as_required_and_then_as_not
    original = RpmsRpc::RegistrationParameters.for_facility(facility)
    file_entry = mandatory_file_entry("2")
    assert file_entry, "the division lists PATIENT (#2) among its mandatory-field files"
    label = "PHONE NUMBER [RESIDENCE]"
    refute RpmsRpc::RegistrationParameters.required?(original, "2", label), "the build does not already require #{label}"

    added = nil
    begin
      filed = in_ddr do
        RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [
          { file: RpmsRpc::RegistrationParameters::MANDATORY_FIELD_FILE, field: ".01", iens: "+1,#{file_entry},#{facility},", value: label },
          { file: RpmsRpc::RegistrationParameters::MANDATORY_FIELD_FILE, field: ".02", iens: "+1,#{file_entry},#{facility},", value: "1" }
        ])
      end
      assert filed && filed[:success], "DDR FILER added the mandatory field: #{filed.inspect}"
      added = filed[:iens][1]

      read = RpmsRpc::RegistrationParameters.for_facility(facility)
      assert RpmsRpc::RegistrationParameters.required?(read, "2", label)
      assert_includes read[:mandatory_fields], { file: "2", field: label, required: true }

      file_row(RpmsRpc::RegistrationParameters::MANDATORY_FIELD_FILE, "#{added},#{file_entry},#{facility},", ".02" => "0")
      read = RpmsRpc::RegistrationParameters.for_facility(facility)
      refute RpmsRpc::RegistrationParameters.required?(read, "2", label)
      assert_includes read[:mandatory_fields], { file: "2", field: label, required: false }
    ensure
      file_row(RpmsRpc::RegistrationParameters::MANDATORY_FIELD_FILE, "#{added},#{file_entry},#{facility},", ".01" => "@") if added
    end
    assert_equal original, RpmsRpc::RegistrationParameters.for_facility(facility), "the added field is removed"
  end

  def test_a_facility_with_no_entry_reads_as_not_on_file
    read = RpmsRpc::RegistrationParameters.for_facility(999_999)
    refute read[:on_file]
    assert(read[:switches].values.all?(&:nil?))
    assert_empty read[:mandatory_fields]
  end

  private

  def in_ddr(&block) = client.with_context(RpmsRpc::RegistrationParameters::CONTEXT, &block)

  def code(value, yes: "Y", no: "N")
    return "@" if value.nil?

    value ? yes : no
  end

  def file_top(values) = file_row(FILE, "#{facility},", values)

  def file_row(file, iens, values)
    rows = values.map { |field, value| { file: file, field: field, iens: iens, value: value } }
    filed = in_ddr { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    assert filed && filed[:success], "DDR FILER filed #{values.inspect} on ##{file} #{iens}: #{filed.inspect}"
  end

  # The #9009061.11 entry for a file, by its .01 (the file number).
  def mandatory_file_entry(file_number)
    page = in_ddr do
      RpmsRpc::DdrFileman.lister(file: RpmsRpc::RegistrationParameters::MANDATORY_FILE, iens: ",#{facility},", fields: "@;.01I", flags: "IP")
    end
    page[:entries].find { |e| e[:pieces].first == file_number }&.dig(:ien)
  end
end
