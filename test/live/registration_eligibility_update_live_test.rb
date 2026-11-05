# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/ddr_fileman"

# rpms-ux S-REG-07.1: the front desk records a patient's tribal standing
# (eligibility status, classification, tribe of membership, Indian blood
# quantum, tribe quantum, enrollment number) through AG's Eligibility window
# (AGG UPDATE PATIENT), and IHS PATIENT (#9000001) holds each value.
class RegistrationEligibilityUpdateLiveTest < LiveSpec::Test
  writes!

  DFN = 990_052 # BRAVO,REESE on the pinned build; unused by other live specs

  ELIGIBILITY_CODES = %w[C D].freeze
  QUANTUM_VALUES = %w[1/2 1/4].freeze

  def test_tribal_standing_is_filed_on_ihs_patient
    before = RpmsRpc::Tribal.enrollment(DFN)
    refute_nil before, "Tribal.enrollment(#{DFN}) must read current standing before filing"

    tribe_rows = Array(RpmsRpc::Tribal.tribes).select { |row| row[:ien].is_a?(Integer) && row[:ien].positive? }
    flunk "need at least two tribes with positive IEN on this build" if tribe_rows.size < 2

    tribe_row = tribe_rows.find { |row| row[:ien].to_s != before[:tribe_ien].to_s }
    flunk "need a tribe distinct from current membership on this build" unless tribe_row
    tribe = tribe_row[:ien].to_s

    eligibility_status = alternate_value(ELIGIBILITY_CODES, before[:eligibility_status].to_s)
    blood_quantum = alternate_value(QUANTUM_VALUES, before[:indian_blood_quantum].to_s)
    tribe_quantum = alternate_value(QUANTUM_VALUES, before[:tribe_quantum].to_s)
    classification = classification_ien!
    classification_before_filing = before[:classification_ien].to_s
    # BENEFICIARY #9999999.25 holds only IEN 1 OTHER on this build — cannot pick a
    # different classification; clear first when already filed so the write is observable.
    if classification_before_filing == classification
      cleared = RpmsRpc::Registration.update(DFN, classification: "")
      assert_equal({ success: true, dfn: DFN }, cleared)
      after_clear = RpmsRpc::Tribal.enrollment(DFN)
      assert_nil after_clear[:classification_ien], "clearing classification must be observable on readback"
      classification_before_filing = after_clear[:classification_ien].to_s
    end

    number = "ZZ#{rand(10_000..99_999)}"

    result = RpmsRpc::Registration.update(DFN, eligibility_status: eligibility_status, classification: classification,
                                               tribe: tribe, blood_quantum: blood_quantum, tribe_quantum: tribe_quantum,
                                               enrollment_number: number)
    assert_equal({ success: true, dfn: DFN }, result)

    got = RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: ".07;1108;1109;1110;1111;1112", flags: "I")
    refute got.nil? || got[:error], "FileMan read of #9000001: #{got.inspect}"
    filed = %w[.07 1108 1109 1110 1111 1112].to_h { |f| [ f, got.dig(:fields, f, :internal).to_s ] }
    expected = { ".07" => number, "1108" => tribe, "1109" => tribe_quantum, "1110" => blood_quantum,
                   "1111" => classification, "1112" => eligibility_status }
    assert_equal expected, filed

    before_internal = {
      ".07" => before[:enrollment_number].to_s,
      "1108" => before[:tribe_ien].to_s,
      "1109" => before[:tribe_quantum].to_s,
      "1110" => before[:indian_blood_quantum].to_s,
      "1111" => classification_before_filing,
      "1112" => before[:eligibility_status].to_s
    }
    expected.each do |field, value|
      refute_equal before_internal[field], value,
                   "field #{field} must differ from pre-test value (#{before_internal[field].inspect} -> #{value.inspect})"
    end

    standing = RpmsRpc::Tribal.enrollment(DFN)
    assert_equal [ number, tribe_quantum, blood_quantum, eligibility_status ],
                 standing.values_at(:enrollment_number, :tribe_quantum, :indian_blood_quantum, :eligibility_status)
    puts "\n#{persona}: tribal standing filed on DFN #{DFN}"
  end

  private

  def alternate_value(options, current)
    options.find { |choice| choice != current.to_s } || options.first
  end

  def classification_ien!
    got = RpmsRpc::DdrFileman.lister(file: "9999999.25", fields: "@;.01", flags: "IP", xref: "B", max: "10")
    entry = Array(got && got[:entries]).first
    flunk "BENEFICIARY #9999999.25 has no entries on this build: #{got.inspect}" unless entry
    entry[:ien].to_s
  end
end
