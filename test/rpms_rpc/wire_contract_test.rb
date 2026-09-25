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
    # (:problem_list was here with divergences [1, 2, 5, 6] — swapped
    # status/description, a fabricated :recorded_date at 5 and a
    # :provider_duz at 6 that this wire has no piece for. #188 corrected the
    # mapping and the gate now reports none, so the entry left with the fix,
    # exactly as this list's contract requires.)
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

  # THE GAP THIS GATE WAS BUILT TO CLOSE, TURNED ON ITSELF.
  #
  # A capture whose reply carried no data rows proves the RPC answered —
  # nothing more. Its `pieces:` block is then hand-written from the M
  # source like any routine-cite, but wears a `live-capture` label, and
  # raw_type_violations (the one check that reads real bytes) iterates an
  # empty array and passes. Absence of data is never verification, so a
  # zero-row capture may not call itself live-capture.
  def test_no_live_capture_fixture_is_actually_empty
    empty = FIXTURES.select { |f| f.source == "live-capture" && f.captured_data_rows.empty? }

    assert_empty empty.map { |f| File.basename(f.path) },
      "these claim live-capture but captured no data rows — re-capture against " \
      "a seeded box, or relabel them source: no-data"
  end

  # The corpus must say out loud how much of it is actually evidence, so a
  # growing pile of no-data fixtures cannot read as growing coverage.
  def test_capture_backed_coverage_is_reported_not_assumed
    backed = FIXTURES.select { |f| f.captured_data_rows.any? }.map(&:mapping_name).sort
    unbacked = (FIXTURES.map(&:mapping_name) - backed).sort

    refute_empty backed, "no mapping has capture-backed evidence"
    puts "\n  wire-contract evidence: #{backed.size} capture-backed " \
         "(#{backed.join(', ')}); #{unbacked.size} source-derived only " \
         "(#{unbacked.join(', ')})"
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
  # when the real wire is IEN^TYPE^value^DATETIME (FASTVIT^ORQQVI — the tag
  # the #8994 registry actually serves this RPC name from, dump line 565;
  # corrected mapping landed in #188). Rebuild that fabricated mapping
  # verbatim and show this gate would have gone RED on it.
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
    # Positions 0-2 only. Position 3 is NOT a free pass for the fabrication —
    # it is a coincidence: the invented layout put a date at piece 4 and
    # FASTVIT really does carry the date/time taken there. (Against the
    # earlier, wrongly-cited VITALS^ORQQVI fixture this read as four
    # mismatches, which flattered the gate.) Three of four inventions caught
    # on shape alone; the fourth needs the type check over real rows.
    assert_equal [ 0, 1, 2 ], violations.map(&:position).sort,
                 "the fabricated TYPE^VALUE^UNITS^DATE layout must be flagged wherever it disagrees"
    assert(violations.all? { |v| v.kind == :attribute_mismatch })

    # ...and the corrected mapping (#188) passes the same gate.
    corrected = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:vitals], fixture)
    assert_empty corrected, corrected.join("; ")
  end
end
