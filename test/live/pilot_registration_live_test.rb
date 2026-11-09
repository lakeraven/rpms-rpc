# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "securerandom"

# Issue #562: live proof that registration fail-closes on #9000001.41 HRN read-back
# under PROV123, and that structured possible-match lookup finds seed DFN 2.
class PilotRegistrationLiveTest < LiveSpec::Test
  writes!

  Ddr = RpmsRpc::DdrFileman

  def synthetic(**extra)
    suffix = SecureRandom.hex(5).tr("0-9", "G-P").upcase
    { name_last: "ZZREG#{suffix}", name_first: "DEMO", dob: Date.new(1903, 1 + rand(12), 1 + rand(28)),
      sex: "F", no_ssn_reason: "N" }.merge(extra)
  end

  def ensure_unused_registration_identity!(attrs)
    params = { "AGGPTLNM" => attrs[:name_last], "AGGPTFNM" => attrs[:name_first] }
    start_dob = attrs[:dob]
    found_free = false
    366.times do
      params["AGGPTDOB"] = attrs[:dob].strftime("%m/%d/%Y")
      candidates = RpmsRpc::Agg.registration_candidates(params)
      flunk("registration_candidates returned nil for #{attrs[:name_last]},#{attrs[:name_first]} " \
            "DOB #{params['AGGPTDOB']} (broker or AG lookup failure)") if candidates.nil?
      if candidates.empty?
        found_free = true
        break
      end
      attrs[:dob] += 1
    end
    return if found_free

    flunk("no unused DOB within 366 days of #{start_dob} for #{attrs[:name_last]},#{attrs[:name_first]}")
  end

  def registration_candidates_for(attrs)
    rows = RpmsRpc::Agg.registration_candidates(
      "AGGPTLNM" => attrs[:name_last],
      "AGGPTFNM" => attrs[:name_first],
      "AGGPTDOB" => attrs[:dob].strftime("%m/%d/%Y")
    )
    flunk("registration_candidates returned nil for #{attrs[:name_last]},#{attrs[:name_first]} " \
          "(broker or AG lookup failure)") if rows.nil?

    rows
  end

  def lookup_hrn_number(attrs, dfn)
    row = registration_candidates_for(attrs).find { |candidate| candidate[:dfn] == dfn }
    raw = row&.dig(:hrn).to_s
    return nil if raw.empty?

    raw.split("-", 2).first
  end

  def hrn_pieces_on_file(dfn)
    listed = Ddr.lister(file: "9000001.41", iens: ",#{dfn},", fields: "@;.02", flags: "IP")
    flunk("DDR LISTER read-back failed for DFN #{dfn}: #{listed.inspect}") if listed.nil? || listed[:error]

    listed[:entries].map { |entry| entry.dig(:pieces, 0).to_s }.reject(&:empty?)
  end

  def assert_registration_hrn_oracles(result, attrs, source:, expected_hrn: nil)
    refute_nil result
    dfn = result[:dfn]
    refute_nil dfn, "registration must return a DFN when AG created the chart"
    on_file = hrn_pieces_on_file(dfn)
    lookup_hrn = lookup_hrn_number(attrs, dfn)
    lookup_row_hrn = registration_candidates_for(attrs).find { |row| row[:dfn] == dfn }&.dig(:hrn)

    if result[:success]
      refute_nil expected_hrn, "success path must name the HRN under test"
      filed = expected_hrn.to_s
      assert_includes on_file, filed,
                      "success requires #9000001.41 to hold the returned HRN (had #{on_file.inspect})"
      assert_equal filed, lookup_hrn,
                   "success requires AG lookup to show the same HRN (lookup row HRN #{lookup_row_hrn.inspect})"
    else
      assert_equal :hrn_file_failed, result[:error]
      refute_includes on_file, expected_hrn.to_s if expected_hrn
      case source
      when :temporary
        refute_match(/\AT\d{5}\z/, lookup_hrn.to_s,
                     "failed temporary registration must not leave a new T-number on the lookup row " \
                     "(had #{lookup_row_hrn.inspect})")
      else
        if expected_hrn && lookup_hrn == expected_hrn.to_s
          flunk("AG lookup shows HRN #{expected_hrn} for DFN #{dfn} but register reported :hrn_file_failed")
        end
      end
    end

    if expected_hrn && lookup_hrn == expected_hrn.to_s
      assert result[:success],
             "a filed HRN visible in AG lookup must not be reported as :hrn_file_failed (DFN #{dfn})"
    end

    refute result[:success] && on_file.empty?, "never success when #9000001.41 is empty"
  end

  %i[derive temporary given].each do |source|
    define_method("test_fail_closed_hrn_filing_for_#{source}_hrn_source") do
      attrs = synthetic(hrn_source: source)
      ensure_unused_registration_identity!(attrs)
      given_hrn = format("%06d", 900_000 + rand(99_999)) if source == :given
      attrs[:hrn] = given_hrn if source == :given

      result = RpmsRpc::Patient.register(attrs, lookup_client: lookup_client)
      refute_equal :duplicate_identity, result[:error],
                   "registration must not fail as duplicate_identity after unused DOB selection"
      expected_hrn =
        case source
        when :derive then result[:dfn].to_s
        when :given then given_hrn
        when :temporary then result[:hrn]
        end
      assert_registration_hrn_oracles(result, attrs, source: source, expected_hrn: expected_hrn)
    end
  end

  def test_possible_match_registration_candidates_include_seed_dfn_two
    rows = RpmsRpc::Agg.registration_candidates(
      "AGGPTLNM" => "USER",
      "AGGPTFNM" => "TEST",
      "AGGPTDOB" => "01/01/1950"
    )
    flunk("registration_candidates returned nil for USER,TEST (broker or AG lookup failure)") if rows.nil?

    dfns = rows.map { |row| row[:dfn] }
    assert_includes dfns, 2,
                    "structured NAME-branch lookup must find USER,TEST (seed DOB 05/05/1985); " \
                    "01/01/1950 is deliberately different from the seed DOB"
  end
end
