# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient"
require_relative "../captured_replies"

# Issue #523: brief_header must use the GETBDP row labelled DESIGNATED PRIMARY
# PROVIDER, not the alphabetically first category.
#
# Replies are the pinned build's, captured while seed patient DFN 2 gained a
# case manager and then a designated primary provider through BEHOPTPC SETBDP
# (test/fixtures/captured_replies/patient-designated-providers.yml), replayed
# through CiaClient. GETBDP lists rows by category name (GETBDP^BEHOPTPC
# walks ALLDP^BDPAPI's array), so CASE MANAGER comes before DESIGNATED
# PRIMARY PROVIDER. The guard tests change one captured reply at the place
# the guard reads; each says what it changes.
class PatientDesignatedProviderTest < Minitest::Test
  SLUG    = "patient-designated-providers"
  DFN     = "2"
  UNKNOWN = "999999999"

  def teardown
    RpmsRpc.reset!
  end

  def raw(name) = CapturedReplies.raw(SLUG, name)

  # PTINFO, GETBDP and CWAD answered with the named captures (or raw bytes).
  def brief_header(ptinfo:, getbdp:, cwad: "cwad", dfn: DFN)
    reply = ->(r) { r.is_a?(Symbol) || r.match?(/\A[a-z_]+\z/) ? raw(r.to_s) : r }
    @client = CapturedReplies::ReplayCiaClient.new(
      "BEHOPTCX PTINFO" => [ reply.(ptinfo) ],
      "BEHOPTPC GETBDP" => [ reply.(getbdp) ],
      "ORWPT CWAD" => [ reply.(cwad) ]
    )
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @client }
    RpmsRpc::Patient.brief_header(dfn)
  end

  # The captured two-row GETBDP reply, with one change made to its bytes.
  def getbdp_primary_with
    yield(raw("getbdp_primary").dup)
  end

  # The case-manager row comes first and must not win.
  def test_brief_header_uses_designated_primary_row_not_first_category
    header = brief_header(ptinfo: "ptinfo_primary", getbdp: "getbdp_primary")

    assert_equal "PROFILE,MD", header[:primary_provider]
  end

  # GETBDP is sent with the DFN as its only parameter.
  def test_brief_header_sends_getbdp_with_the_dfn_only
    brief_header(ptinfo: "ptinfo_primary", getbdp: "getbdp_primary")

    call = @client.calls.find { |c| c[:rpc] == "BEHOPTPC GETBDP" }
    assert_equal [ DFN ], call[:params]
  end

  # Only a case manager on file: the header does not borrow that category's name.
  def test_brief_header_primary_provider_nil_with_only_a_case_manager
    header = brief_header(ptinfo: "ptinfo_case_manager", getbdp: "getbdp_case_manager")

    refute_nil header
    assert_nil header[:primary_provider]
  end

  # No designation at all: a header with no primary provider.
  def test_brief_header_primary_provider_nil_with_no_designation
    header = brief_header(ptinfo: "ptinfo_none", getbdp: "getbdp_none")

    assert_equal "USER,TEST", header[:name]
    assert_nil header[:primary_provider]
  end

  # When GETBDP is refused, PTINFO piece 18 (the designated primary provider,
  # as BEHOPTCX reads it) stands in: here the designated row itself is altered,
  # so only PTINFO can answer PROFILE,MD.
  def test_brief_header_falls_back_to_ptinfo_primary_when_getbdp_is_refused
    altered = getbdp_primary_with { |r| r.sub("^PROFILE,MD^".b, "^PROFIL\xC9,MD^".b) }

    header = brief_header(ptinfo: "ptinfo_primary", getbdp: altered)

    assert_equal "PROFILE,MD", header[:primary_provider]
  end

  # A DFN no patient has: PTINFO and GETBDP answer nothing, so there is no header.
  def test_brief_header_nil_for_a_dfn_no_patient_has
    assert_nil brief_header(ptinfo: "ptinfo_unknown", getbdp: "getbdp_unknown", cwad: "cwad", dfn: UNKNOWN)
  end

  # Guard: an empty PTINFO with only a case-manager row is still not a patient.
  def test_brief_header_nil_when_ptinfo_is_empty_and_getbdp_has_rows
    assert_nil brief_header(ptinfo: "ptinfo_unknown", getbdp: "getbdp_case_manager")
  end

  # The guards below take PTINFO with no primary provider (only a case manager
  # is on file), so a nil primary provider shows the GETBDP read was refused:
  # had the changed row been read, PROFILE,MD would be the answer.

  # Guard: a byte that is not UTF-8 in the case-manager row (CIA decodes it to
  # U+FFFD and marks the reply altered) fails the whole GETBDP read.
  def test_brief_header_refuses_getbdp_when_the_reply_is_altered
    altered = getbdp_primary_with { |r| r.sub("PROFILE,REG".b, "PROFIL\xC9,REG".b) }

    header = brief_header(ptinfo: "ptinfo_case_manager", getbdp: altered)

    assert_nil header[:primary_provider]
  end

  # Guard: an error row before the designated row fails the whole read.
  def test_brief_header_refuses_getbdp_with_an_error_row
    with_error = getbdp_primary_with { |r| r.sub("DESIGNATED".b, "-1^boom\rDESIGNATED".b) }

    header = brief_header(ptinfo: "ptinfo_case_manager", getbdp: with_error)

    assert_nil header[:primary_provider]
  end

  # Guard: a C0 control left inside a row fails the read.
  def test_brief_header_refuses_getbdp_when_a_row_holds_a_control_character
    with_control = getbdp_primary_with { |r| r.sub("PROVIDER^PROFILE,MD".b, "PROVIDER^\x1EPROFILE,MD".b) }

    header = brief_header(ptinfo: "ptinfo_case_manager", getbdp: with_control)

    assert_nil header[:primary_provider]
  end

  # Guard: a designated row with a blank provider name is not a designation.
  def test_brief_header_ignores_a_designated_row_with_a_blank_name
    blank = getbdp_primary_with { |r| r.sub("PROVIDER^PROFILE,MD^".b, "PROVIDER^ ^".b) }

    header = brief_header(ptinfo: "ptinfo_case_manager", getbdp: blank)

    assert_nil header[:primary_provider]
  end
end
