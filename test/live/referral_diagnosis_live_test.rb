# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.update files a diagnosis and Referral.find reads it back
# (rpms-rpc#915), as the provider, on a referral the spec files with DDR
# FILER for demo patient 990001. Before openrpms#1271's fix (first released
# in bcer-9.0-20261124-60d39b6-ydb) BMC GET REFERRAL dies reading a
# diagnosis, and the spec skips by that issue.
class ReferralDiagnosisLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  def file_referral
    d = Date.today
    values = { ".01" => format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day), ".02" => "9#{Time.now.to_i}"[0, 13], ".03" => "990001",
               ".04" => "N", ".14" => "O", ".15" => "A" }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: values.map { |f, v| { file: "90001", field: f, iens: "+1,", value: v } })
    assert filed && filed[:success], "DDR FILER could not file a referral: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  def test_a_diagnosis_filed_by_update_reads_back_and_an_unknown_code_files_nothing
    ien = file_referral
    assert RpmsRpc::Referral.update(ien, diagnosis_code: "E11.9", diagnosis_narrative: "Type 2 diabetes mellitus")[:success]

    begin
      record = RpmsRpc::Referral.find(ien)
    rescue RpmsRpc::Client::RpcMError => e
      return skip_tracked("openrpms#1271", "BMC GET REFERRAL dies reading the diagnosis: #{e.message[0, 80]}")
    end
    assert_equal [ [ "E11.9", "Type 2 diabetes mellitus" ] ], record[:diagnoses].map { |d| d.values_at(:icd_code, :narrative) }

    refute RpmsRpc::Referral.update(ien, diagnosis_code: "ZZZ.99", diagnosis_narrative: "No such code")[:success]
    assert_equal [ "E11.9" ], RpmsRpc::Referral.find(ien)[:diagnoses].map { |d| d[:icd_code] }, "the diagnosis on file stays"
  end
end
