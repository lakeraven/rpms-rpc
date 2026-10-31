# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/reply"
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

  # fetch_many drops "-N^message" lines but keeps others; any error row means a failed GETBDP read.
  def test_brief_header_falls_back_to_ptinfo_when_getbdp_leads_with_error_row
    getbdp = [
      "-1^boom",
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED")
    ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Same fail-closed rule when a valid row precedes the error and a designated row follows.
  def test_brief_header_falls_back_to_ptinfo_when_getbdp_contains_an_error_row_among_data_rows
    getbdp = [
      bdp_row("CASE MANAGER", "MANAGER,CASE"),
      "-1^boom",
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED")
    ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Sole "-1^no data" String is an empty GETBDP read, not a provider row.
  def test_brief_header_falls_back_to_ptinfo_when_getbdp_is_only_error_string
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: "-1^no data"
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # MockClient / Reply::Text shape: newline body with no error rows still selects designated primary.
  def test_brief_header_uses_designated_primary_from_newline_joined_getbdp_string
    getbdp = [
      bdp_row("CASE MANAGER", "MANAGER,CASE"),
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED")
    ].join("\n")
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,DESIGNATED", header[:primary_provider]
  end

  # Empty PTINFO means unknown patient; GETBDP alone must not yield a nil-field header.
  def test_brief_header_nil_when_ptinfo_empty_and_getbdp_cannot_establish_presence
    client_case_only = BriefHeaderClient.new(
      ptinfo_line: "",
      getbdp_lines: [ bdp_row("CASE MANAGER", "MANAGER,CASE") ]
    )
    assert_nil brief_header(client_case_only)

    client_dpp_blank_name = BriefHeaderClient.new(
      ptinfo_line: "",
      getbdp_lines: [ bdp_row("DESIGNATED PRIMARY PROVIDER", "") ]
    )
    assert_nil brief_header(client_dpp_blank_name)
  end

  # $C(31) unit separator must not hide a trailing error row; treat GETBDP as failed read.
  def test_brief_header_falls_back_to_ptinfo_when_error_row_follows_unit_separator
    dpp = bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED")

    client_string = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: "\x1f\n-1^boom\n#{dpp}"
    )
    assert_equal "PROVIDER,PTINFO", brief_header(client_string)[:primary_provider]

    client_array = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: [ "#{dpp}\x1f-1^boom" ]
    )
    assert_equal "PROVIDER,PTINFO", brief_header(client_array)[:primary_provider]
  end

  # Invalid UTF-8 on a sibling row must not raise; fail closed to PTINFO primary.
  def test_brief_header_survives_invalid_utf8_among_getbdp_rows
    bad_line = "CASE MANAGER^M\xC9NDEZ,X^5^^".b.force_encoding(Encoding::UTF_8)
    getbdp = [
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED"),
      bad_line
    ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # NBSP-only provider name is not a real designation; use PTINFO primary like ASCII blank.
  def test_brief_header_falls_back_to_ptinfo_when_designated_primary_name_is_nbsp_only
    getbdp = [ bdp_row("DESIGNATED PRIMARY PROVIDER", "\u00A0") ]
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # CIA clients decode invalid bytes to U+FFFD; altered? is set but the UTF-8 guard never runs.
  def test_brief_header_falls_back_to_ptinfo_when_cia_reply_alters_designated_primary_row
    getbdp = RpmsRpc::Reply.from_wire(
      [
        "CASE MANAGER^MANAGER,CASE^1^^",
        "DESIGNATED PRIMARY PROVIDER^PROVID\xC9R,X^5^^".b
      ],
      controls: true
    )
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # XWB order with an altered sibling row: Reply is valid UTF-8 so the raw-byte guard does not fail the read.
  def test_brief_header_falls_back_to_ptinfo_when_xwb_reply_alters_a_sibling_row
    getbdp = RpmsRpc::Reply.from_wire(
      [
        "DESIGNATED PRIMARY PROVIDER^PROVIDER,DESIGNATED^5^^",
        "CASE MANAGER^PROVID\xC9R,X^5^^".b
      ]
    )
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Altered CIA GETBDP with empty PTINFO must not fabricate a header from scrubbed provider text.
  def test_brief_header_nil_when_ptinfo_empty_and_cia_getbdp_reply_is_altered
    getbdp = RpmsRpc::Reply.from_wire(
      [
        "CASE MANAGER^MANAGER,CASE^1^^",
        "DESIGNATED PRIMARY PROVIDER^PROVID\xC9R,X^5^^".b
      ],
      controls: true
    )
    client = BriefHeaderClient.new(
      ptinfo_line: "",
      getbdp_lines: getbdp
    )

    assert_nil brief_header(client)
  end

  # MockClient String bodies use Reply.text; scrubbed bytes mark altered? without tripping invalid-UTF-8 checks.
  def test_brief_header_falls_back_to_ptinfo_when_reply_text_body_is_altered
    body = [
      bdp_row("DESIGNATED PRIMARY PROVIDER", "PROVIDER,DESIGNATED"),
      "CASE MANAGER^PROVID\xC9R,X^5^^"
    ].join("\n").b
    getbdp = RpmsRpc::Reply.text(body)
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Without controls: true, an in-row C0 control is still valid UTF-8 and is not stripped before parsing.
  def test_brief_header_falls_back_to_ptinfo_when_reply_row_contains_control_character
    getbdp = RpmsRpc::Reply.from_wire([ "DESIGNATED PRIMARY PROVIDER^\x1eOTHER^REAL^1" ])
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # A CR inside a String GETBDP splits rows; the designated-primary label alone is not a usable row.
  def test_brief_header_falls_back_to_ptinfo_when_getbdp_string_embeds_carriage_return
    getbdp = "DESIGNATED PRIMARY PROVIDER^\rCASE MANAGER^MANAGER,CASE^1"
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,PTINFO", header[:primary_provider]
  end

  # Clean CIA-shaped Reply must still select the designated-primary row (regression once altered? is honored).
  def test_brief_header_uses_designated_primary_from_clean_cia_shaped_reply
    getbdp = RpmsRpc::Reply.from_wire(
      [
        "CASE MANAGER^MANAGER,CASE^1^^",
        "DESIGNATED PRIMARY PROVIDER^PROVIDER,DESIGNATED^5^^"
      ],
      controls: true
    )
    client = BriefHeaderClient.new(
      ptinfo_line: ptinfo_line(primary_provider: "PROVIDER,PTINFO"),
      getbdp_lines: getbdp
    )

    header = brief_header(client)

    assert_equal "PROVIDER,DESIGNATED", header[:primary_provider]
  end
end
