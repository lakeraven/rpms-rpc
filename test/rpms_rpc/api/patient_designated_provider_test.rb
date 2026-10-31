# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient"

# Issue #523: brief_header must use the GETBDP row labelled DESIGNATED PRIMARY
# PROVIDER, not the alphabetically first category. Hermetic doubles only.
class PatientDesignatedProviderTest < Minitest::Test
  DFN = "8791"

  # Answers PTINFO, GETBDP (multi-line array, like CIA #call_rpc), and CWAD.
  class BriefHeaderClient
    def initialize(ptinfo_line:, getbdp_lines:, cwad: "")
      @ptinfo_line = ptinfo_line
      @getbdp_lines = getbdp_lines
      @cwad = cwad
    end

    def call_rpc(rpc, *_params)
      case rpc
      when "BEHOPTCX PTINFO" then @ptinfo_line
      when "BEHOPTPC GETBDP" then @getbdp_lines
      when "BEHOCACV CWAD" then @cwad
      else ""
      end
    end

    def call_rpc_lines(rpc, *params) = call_rpc(rpc, *params)
  end

  def teardown
    RpmsRpc.reset!
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  def ptinfo_line(primary_provider: "PROVIDER,PRIMARY", **overrides)
    parts = Array.new(20, "")
    parts[0]  = overrides.fetch(:name, "PATIENT,TEST")
    parts[1]  = overrides.fetch(:sex, "M")
    parts[2]  = overrides.fetch(:dob_raw, "2860701")
    parts[10] = overrides.fetch(:mrn, "HRN0008791")
    parts[17] = primary_provider.to_s
    parts.join("^")
  end

  def bdp_row(label, provider_name, ien: 101, title: "PHYSICIAN", date_raw: "3250101")
    [ label, provider_name, ien, title, date_raw ].join("^")
  end

  def brief_header(client)
    use(client)
    RpmsRpc::Patient.brief_header(DFN)
  end

  # Alphabetical GETBDP must not win over the designated-primary row.
  def test_brief_header_uses_designated_primary_provider_row_not_first_category
    getbdp = [
      bdp_row("CASE MANAGER", "MANAGER,CASE"),
      bdp_row("DESIGNATED MENTAL HEALTH PROVIDER", "PROVIDER,MENTAL"),
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED")
    ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,DESIGNATED", header[:primary_provider]
  end

  # No designated-primary label: keep PTINFO primary, not another category's name.
  def test_brief_header_falls_back_to_ptinfo_when_no_designated_primary_label
    getbdp = [
      bdp_row("CASE MANAGER", "MANAGER,CASE"),
      bdp_row("DESIGNATED MENTAL HEALTH PROVIDER", "PROVIDER,MENTAL")
    ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Without a designated-primary row or PTINFO primary, do not borrow another category.
  def test_brief_header_primary_provider_nil_when_only_unlabeled_getbdp_and_no_ptinfo_primary
    getbdp = [ bdp_row("CASE MANAGER", "MANAGER,CASE") ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: nil),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_nil header[:primary_provider]
  end

  # Blank name on the designated-primary row: fall back to PTINFO primary.
  def test_brief_header_falls_back_to_ptinfo_when_designated_primary_name_blank
    getbdp = [ bdp_row("DESIGNATED PRIMARY PROVIDER", "") ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Single designated-primary row still wins (regression guard once selection is fixed).
  def test_brief_header_chooses_designated_primary_when_it_is_the_only_getbdp_row
    getbdp = [ bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED") ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,DESIGNATED", header[:primary_provider]
  end
end
