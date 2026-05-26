# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/care_team"

class CareTeamTest < Minitest::Test
  # Participants sub-encoded format: DUZ~NAME~ROLE~START~END;DUZ~NAME~ROLE~START~END.
  # Trailing fields may be empty — first chunk uses `~~` placeholders to demonstrate
  # the 5-field shape is preserved even when START/END are blank.
  PARTICIPANTS_RAW = "301~SMITH,JANE~primary~~;405~JONES,BOB~consulting~3260101~3260601"

  def setup
    RpmsRpc.mock! do |m|
      # ORQQCT LIST — keyed by patient DFN, multi-line.
      m.seed_keyed_collection(:care_team_list, "8791", [
        {
          ien: "501",
          team_name: "Primary Care Team",
          status: "active",
          category: "longitudinal",
          start_date: nil,
          end_date: nil,
          participants_raw: PARTICIPANTS_RAW,
          reason_code: "Z00.00",
          reason_display: "General adult medical examination",
          organization: "Test Clinic"
        },
        {
          ien: "502",
          team_name: "Endocrinology Team",
          status: "",           # API should default to "active"
          category: nil,
          start_date: nil,
          end_date: nil,
          participants_raw: nil, # API should yield empty []
          reason_code: nil,
          reason_display: nil,
          organization: nil
        }
      ])

      # ORQQCT GET — single-line field-based response, keyed by IEN.
      m.seed(:care_team_detail, "501", {
        team_name: "Primary Care Team",
        status: "active",
        category: "longitudinal",
        start_date: nil,
        end_date: nil,
        participants_raw: PARTICIPANTS_RAW,
        reason_code: "Z00.00",
        reason_display: "General adult medical examination",
        organization: "Test Clinic",
        patient_dfn: 8791
      })

      m.seed(:care_team_detail, "503_NO_PARTICIPANTS", {
        team_name: "Empty Team",
        status: nil,
        category: nil,
        start_date: nil,
        end_date: nil,
        participants_raw: nil,
        reason_code: nil,
        reason_display: nil,
        organization: nil,
        patient_dfn: 8791
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # === for_patient ==========================================================

  def test_for_patient_returns_care_teams
    teams = RpmsRpc::CareTeam.for_patient(8791)

    assert_kind_of Array, teams
    assert_equal 2, teams.length
    pc = teams.find { |t| t[:team_name] == "Primary Care Team" }
    refute_nil pc
    assert_equal "active",       pc[:status]
    assert_equal "longitudinal", pc[:category]
    assert_equal "Z00.00",       pc[:reason_code]
    assert_equal "Test Clinic",  pc[:organization]
  end

  def test_for_patient_parses_participants_into_hashes
    teams = RpmsRpc::CareTeam.for_patient(8791)
    pc = teams.find { |t| t[:team_name] == "Primary Care Team" }
    participants = pc[:participants]

    assert_kind_of Array, participants
    assert_equal 2, participants.length

    smith = participants.find { |p| p[:duz] == "301" }
    refute_nil smith
    assert_equal "SMITH,JANE", smith[:name]
    assert_equal "primary",    smith[:role]
    assert_nil   smith[:start_date], "blank trailing fields should normalize to nil"
    assert_nil   smith[:end_date]

    jones = participants.find { |p| p[:duz] == "405" }
    refute_nil jones
    assert_equal "consulting", jones[:role]
    assert_equal "3260101",    jones[:start_date]
    assert_equal "3260601",    jones[:end_date]
  end

  def test_for_patient_defaults_status_and_yields_empty_participants_when_blank
    teams = RpmsRpc::CareTeam.for_patient(8791)
    endo = teams.find { |t| t[:team_name] == "Endocrinology Team" }
    refute_nil endo
    assert_equal "active", endo[:status]
    assert_equal [],       endo[:participants]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::CareTeam.for_patient(nil)
    assert_equal [], RpmsRpc::CareTeam.for_patient("")
    assert_equal [], RpmsRpc::CareTeam.for_patient(0)
  end

  def test_for_patient_returns_empty_for_unknown_dfn
    assert_equal [], RpmsRpc::CareTeam.for_patient(999_999)
  end

  # === find =================================================================

  def test_find_returns_single_team
    team = RpmsRpc::CareTeam.find(501)

    refute_nil team
    assert_equal 501,                  team[:ien]
    assert_equal "Primary Care Team",  team[:team_name]
    assert_equal "active",             team[:status]
    assert_equal "longitudinal",       team[:category]
    assert_equal "Test Clinic",        team[:organization]
    assert_equal 8791,                 team[:patient_dfn]
  end

  def test_find_parses_participants_in_detail_response
    team = RpmsRpc::CareTeam.find(501)
    assert_equal 2, team[:participants].length
    smith = team[:participants].find { |p| p[:duz] == "301" }
    assert_equal "SMITH,JANE", smith[:name]
  end

  def test_find_defaults_status_and_empty_participants_for_blank_response
    team = RpmsRpc::CareTeam.find("503_NO_PARTICIPANTS")
    refute_nil team
    assert_equal "active", team[:status]
    assert_equal [],       team[:participants]
  end

  def test_find_returns_nil_for_blank_or_nonpositive_ien
    assert_nil RpmsRpc::CareTeam.find(nil)
    assert_nil RpmsRpc::CareTeam.find("")
    assert_nil RpmsRpc::CareTeam.find(0)
    assert_nil RpmsRpc::CareTeam.find(-5)
  end

  def test_find_returns_nil_for_unknown_ien
    assert_nil RpmsRpc::CareTeam.find(999_998)
  end
end
