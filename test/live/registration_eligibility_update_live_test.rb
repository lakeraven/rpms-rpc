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

  def test_tribal_standing_is_filed_on_ihs_patient
    tribe = tribe_ien!("KWETHLUK")
    classification = classification_ien!
    number = "ZZ#{rand(10_000..99_999)}"

    result = RpmsRpc::Registration.update(DFN, eligibility_status: "C", classification: classification, tribe: tribe,
                                               blood_quantum: "1/2", tribe_quantum: "1/4", enrollment_number: number)
    assert_equal({ success: true, dfn: DFN }, result)

    got = RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: ".07;1108;1109;1110;1111;1112", flags: "I")
    refute got.nil? || got[:error], "FileMan read of #9000001: #{got.inspect}"
    filed = %w[.07 1108 1109 1110 1111 1112].to_h { |f| [ f, got.dig(:fields, f, :internal).to_s ] }
    assert_equal({ ".07" => number, "1108" => tribe, "1109" => "1/4", "1110" => "1/2", "1111" => classification, "1112" => "C" },
                 filed)

    standing = RpmsRpc::Tribal.enrollment(DFN)
    assert_equal [ number, "1/4", "1/2", "C" ],
                 standing.values_at(:enrollment_number, :tribe_quantum, :indian_blood_quantum, :eligibility_status)
    puts "\n#{persona}: tribal standing filed on DFN #{DFN}"
  end

  private

  def tribe_ien!(part)
    found = Array(RpmsRpc::Tribal.tribes(part: part)).first
    flunk "no tribe starting #{part} on this build" unless found
    found[:ien].to_s
  end

  def classification_ien!
    got = RpmsRpc::DdrFileman.lister(file: "9999999.25", fields: "@;.01", flags: "IP", xref: "B", max: "10")
    entry = Array(got && got[:entries]).first
    flunk "BENEFICIARY #9999999.25 has no entries on this build: #{got.inspect}" unless entry
    entry[:ien].to_s
  end
end
