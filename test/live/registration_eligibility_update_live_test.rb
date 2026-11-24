# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/ddr_fileman"

# rpms-ux S-REG-07.1: the front desk records a patient's tribal standing
# (eligibility status, classification, tribe of membership, Indian blood
# quantum, tribe quantum, enrollment number) through AG's Eligibility window
# (AGG UPDATE PATIENT), and IHS PATIENT (#9000001) holds each value.
#
# The spec reads the patient's standing first and files a different value
# for every field, so a write that filed nothing fails, on the first run and
# on every run after it on the same container (rpms-rpc#701).
class RegistrationEligibilityUpdateLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  proves "S-REG-07.1"
  writes!

  DFN = 990_052 # BRAVO,REESE, a synthetic panel patient; unused by other live specs
  FIELDS = %w[.07 1108 1109 1110 1111 1112].freeze
  ELIGIBILITY_CODES = %w[C D].freeze
  QUANTA = %w[1/2 1/4].freeze
  CLASSIFICATIONS = [ "INDIAN/ALASKA NATIVE", "OTHER" ].freeze
  TRIBES = "KWETHLUK"

  def test_tribal_standing_is_filed_on_ihs_patient
    before = filed_values
    wanted = {
      ".07" => "ZZ#{rand(10_000..99_999)}",
      "1108" => other(tribe_iens, before["1108"]),
      "1109" => other(QUANTA, before["1109"]),
      "1110" => other(QUANTA, before["1110"]),
      "1111" => other(CLASSIFICATIONS.map { |name| classification_ien!(name) }, before["1111"]),
      "1112" => other(ELIGIBILITY_CODES, before["1112"])
    }
    FIELDS.each { |f| refute_equal before[f], wanted[f], "field #{f} would be filed with the value it holds" }

    result = RpmsRpc::Registration.update(DFN, enrollment_number: wanted[".07"], tribe: wanted["1108"],
                                               tribe_quantum: wanted["1109"], blood_quantum: wanted["1110"],
                                               classification: wanted["1111"], eligibility_status: wanted["1112"])
    assert_equal({ success: true, dfn: DFN }, result)

    assert_equal wanted, filed_values, "IHS PATIENT holds what AG's Eligibility window filed"
    standing = RpmsRpc::Tribal.enrollment(DFN)
    assert_equal wanted.values_at(".07", "1109", "1110", "1112"),
                 standing.values_at(:enrollment_number, :tribe_quantum, :indian_blood_quantum, :eligibility_status)
    assert_equal [ wanted["1108"].to_i, wanted["1111"].to_i ], standing.values_at(:tribe_ien, :classification_ien)
  end

  private

  # The six fields' internal values on #9000001, "" when empty.
  def filed_values
    got = RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: FIELDS.join(";"), flags: "I")
    flunk "FileMan read of #9000001 #{DFN}: #{got.inspect}" if got.nil? || got[:error]
    FIELDS.to_h { |f| [ f, got.dig(:fields, f, :internal).to_s ] }
  end

  def other(choices, current)
    choices.find { |choice| choice != current } || flunk("no value other than #{current.inspect} among #{choices.inspect}")
  end

  def tribe_iens
    iens = Array(RpmsRpc::Tribal.tribes(part: TRIBES)).map { |row| row[:ien].to_s }
    flunk "fewer than two tribes start #{TRIBES} on this build" if iens.size < 2
    iens.first(2)
  end

  def classification_ien!(name)
    got = RpmsRpc::DdrFileman.lister(file: "9999999.25", fields: "@;.01", flags: "IP", xref: "B", part: name, max: "1")
    ien = Array(got && got[:entries]).first&.dig(:ien).to_s
    flunk "no classification #{name} in BENEFICIARY (#9999999.25): #{got.inspect}" if ien.empty?
    ien
  end
end
