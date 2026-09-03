# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"

# The wire-contract CI gate (issue #189, docs/WIRE_CONTRACTS.md).
#
# Runs against COMMITTED fixtures only — no live container. For every
# mapping with a committed capture in test/fixtures/wire_captures/, assert
# the mapping's declared field layout is consistent with the captured /
# routine-cited real return: the piece a mapping calls :type or :date
# actually IS that on the wire, and typed fields survive the captured raw.
#
# This is the anti-fabrication gate: a mock's wire shape mirrors its
# author's belief, so mapping + mock-driven test can agree while both are
# wrong about the real system (ORQQVI VITALS shipped TYPE^VALUE^UNITS^DATE
# against a real wire of IEN^TYPE^DATETIME^value and stayed green). Green
# here means the declared shape matches evidence, not belief.
class RpmsRpc::WireContractTest < Minitest::Test
  FIXTURES = RpmsRpc::WireCapture::Fixture.load_all.freeze

  # Divergences the gate has already CAUGHT in mappings this branch must not
  # touch (mapping fixes belong to their own reviewed PRs — the capture side
  # never edits a mapping to make itself pass). Each entry pins the exact
  # violating positions: if the mapping is fixed, or drifts further, this
  # test fails and the entry must be updated/removed with the fix.
  KNOWN_DIVERGENCES = {
    # :problem_list declares IEN^STATUS^DESCRIPTION^ICD^ONSET^RECORDED^
    # PROVIDER_DUZ; LIST^ORQQPL really returns IEN^NARRATIVE^STATUS^ICD^
    # ONSET^LAST-MODIFIED^SC^SP-EXP^TRANSCRIBED^PRIORITY (ORQQPL.m:3-18 over
    # GMPLUTL3.m:76-99): status/description are swapped, position 5 is
    # date-last-modified (not date-recorded), position 6 is the
    # service-connected flag (no provider DUZ anywhere on this wire).
    problem_list: [ 1, 2, 5, 6 ],
    # :patient_id_info declares position 3 :race_code and position 5
    # :site_ien; IDINFO^ORWPT (ORWPT.m:6-11) returns PID^DOB^SEX^VET^SC%^
    # WARD^RM-BED^NAME — position 3 is the VETERAN flag (the live "N" that
    # was read as a race code) and position 5 the current ward location.
    patient_id_info: [ 3, 5 ]
  }.freeze

  def test_a_curated_capture_corpus_is_committed
    refute_empty FIXTURES, "no wire captures committed — run rake wire:capture"
    assert_operator FIXTURES.size, :>=, 10
  end

  def test_every_fixture_gates_a_registered_mapping
    FIXTURES.each do |fixture|
      assert RpmsRpc::DataMapper.respond_to?(fixture.mapping_name),
             "#{fixture.path}: mapping :#{fixture.mapping_name} is not registered"
    end
  end

  # The gate proper: each committed capture against its mapping.
  def test_mappings_match_their_captured_wire_shapes
    failures = []
    FIXTURES.each do |fixture|
      next if KNOWN_DIVERGENCES.key?(fixture.mapping_name)

      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      RpmsRpc::WireCapture::Contract.check(mapping, fixture).each do |violation|
        failures << "#{fixture.mapping_name} (#{fixture.rpc}, #{fixture.source}): #{violation}"
      end
    end
    assert_empty failures, "wire-contract violations:\n  #{failures.join("\n  ")}"
  end

  # Catches in mappings owned by other PRs: the gate DID flag these, and
  # must keep flagging exactly these positions until the mapping-side fix
  # lands (then this entry comes out and the mapping joins the green path).
  def test_known_divergences_are_still_detected_exactly
    KNOWN_DIVERGENCES.each do |mapping_name, positions|
      fixture = FIXTURES.find { |f| f.mapping_name == mapping_name }
      refute_nil fixture, "no fixture for known divergence :#{mapping_name}"

      mapping = RpmsRpc::DataMapper[mapping_name]
      violations = RpmsRpc::WireCapture::Contract.check(mapping, fixture)
      assert_equal positions, violations.map(&:position).uniq.sort,
                   ":#{mapping_name} divergence set changed — the mapping was fixed " \
                   "(remove the KNOWN_DIVERGENCES entry) or drifted (investigate):\n  " +
                   violations.map(&:to_s).join("\n  ")
    end
  end

  # -- The demonstration this gate exists for (issue #189 acceptance) --------
  #
  # The ORQQVI VITALS mapping shipped on main declaring TYPE^VALUE^UNITS^DATE
  # — authored from belief, green against mocks that mirrored the belief —
  # when the real wire is IEN^TYPE^DATETIME^value (VITALS^ORQQVI:
  # ORQQVI.m:4-24; corrected mapping landed in #188, which this branch builds
  # on). Rebuild that fabricated mapping verbatim and show this gate would
  # have gone RED on it at every position.
  def test_gate_red_flags_the_fabricated_orqqvi_vitals_mapping
    fabricated = RpmsRpc::DataMapper::Mapping.new(:fabricated_vitals)
    fabricated.configure do
      rpc "ORQQVI VITALS"
      field 0, :type
      field 1, :value
      field 2, :units
      field 3, :recorded_date, :fileman_date
    end

    fixture = FIXTURES.find { |f| f.rpc == "ORQQVI VITALS" }
    refute_nil fixture

    violations = RpmsRpc::WireCapture::Contract.check(fabricated, fixture)
    assert_equal [ 0, 1, 2, 3 ], violations.map(&:position).sort,
                 "the fabricated TYPE^VALUE^UNITS^DATE layout must be flagged at all four positions"
    assert(violations.all? { |v| v.kind == :attribute_mismatch })

    # ...and the corrected mapping (#188) passes the same gate.
    corrected = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:vitals], fixture)
    assert_empty corrected, corrected.join("; ")
  end
end
