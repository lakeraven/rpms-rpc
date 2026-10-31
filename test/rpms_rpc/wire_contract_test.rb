# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
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
  ROOT = File.expand_path("../..", __dir__)
  WIRE_RAKE_PATH = File.join(ROOT, "lib/tasks/wire.rake")
  FIXTURES = RpmsRpc::WireCapture::Fixture.load_all.freeze

  # Issue #224 chart-read slice — always require signed_on_as on live/no-data fixtures.
  CHART_READ_SLICE_MAPPINGS = %i[
    patient_id_info patient_ptinfo patient_designated_provider patient_cwad
    problem_list allergy_list medication_active vitals
  ].freeze

  # Live captures stamped before #224 round-2 omit signed_on_as; grandfather until re-captured.
  SIGNED_ON_AS_INTRODUCED_ON = Date.new(2026, 10, 30)

  # Divergences the gate has already CAUGHT in mappings this branch must not
  # touch (mapping fixes belong to their own reviewed PRs — the capture side
  # never edits a mapping to make itself pass). Each entry pins the exact
  # violating positions: if the mapping is fixed, or drifts further, this
  # test fails and the entry must be updated/removed with the fix.
  #
  # Empty since #191: the two divergences the gate caught on its first run
  # are fixed. :problem_list ([1, 2, 5, 6] — swapped status/description, a
  # fabricated :recorded_date at 5 and a :provider_duz at 6 that the wire
  # has no piece for) was corrected by #188; :patient_id_info ([3, 5] — the
  # VETERAN flag read as :race_code, the ward location as :site_ien) by
  # #191. Both left this list with their fixes, as its contract requires.
  KNOWN_DIVERGENCES = {}.freeze

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

  # signed_on_as records which synthetic persona made a live broker call (#224 round-2).
  # Routine-cite fixtures cite M source only — they must not carry it.
  def test_routine_cite_fixtures_do_not_record_signed_on_as
    failures = []
    FIXTURES.select { |f| f.source == "routine-cite" }.each do |fixture|
      data = YAML.safe_load_file(fixture.path)
      next unless data.key?("signed_on_as")

      failures << "#{File.basename(fixture.path)}: routine-cite must not include signed_on_as"
    end
    assert_empty failures, failures.join("\n  ")
  end

  # signed_on_as records which synthetic persona made a live broker call (#224 round-2).
  # Required on every #224 chart-read slice fixture and on any other live-capture or
  # no-data fixture whose captured_at is on or after SIGNED_ON_AS_INTRODUCED_ON. Older
  # fixtures (e.g. orwpt-select, behoencx-*) are grandfathered until re-captured.
  def test_live_capture_and_no_data_fixtures_record_signed_on_as
    failures = []
    FIXTURES.select { |f| signed_on_as_required?(f) }.each do |fixture|
      data = YAML.safe_load_file(fixture.path)
      persona = data["signed_on_as"]
      if persona.nil? || persona.to_s.empty?
        failures << "#{File.basename(fixture.path)} (#{fixture.source}): missing signed_on_as"
      elsif !%w[SYS123 PROV123].include?(persona)
        failures << "#{File.basename(fixture.path)}: signed_on_as #{persona.inspect} is not a README synthetic persona"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # lib/tasks/wire.rake must not stamp signed_on_as onto routine-cite rewrites.
  def test_wire_rake_routine_cite_branch_omits_signed_on_as_from_fixture_payload
    src = File.read(WIRE_RAKE_PATH)
    routine_branch = src[/else\s*\n\s*data = fixture_data\(entry, release, captured_at, acc\)\.merge\("source" => "routine-cite"\)[^\n]*/m]
    refute_nil routine_branch, "could not locate routine-cite branch in lib/tasks/wire.rake"
    assert routine_branch.include?('delete("signed_on_as")'),
           "lib/tasks/wire.rake routine-cite branch must drop signed_on_as from fixture_data " \
           "(signed_on_as is live-call provenance only — #224 round-2 SPEC)"
  end

  # no-data captures are live calls that returned no layout rows — the fixture header must say so.
  # Replaces the old "no live call" header text still written by lib/tasks/wire.rake until fixed.
  def test_no_data_fixture_headers_honest_about_empty_live_reply
    failures = []
    FIXTURES.select { |f| f.source == "no-data" }.each do |fixture|
      comments = File.readlines(fixture.path, chomp: true).take(5).select { |l| l.start_with?("#") }.join("\n")
      if comments.match?(/no live call/i)
        failures << "#{File.basename(fixture.path)}: header must not deny the live call"
      end
      unless comments.match?(/live call returned no data rows/i)
        failures << "#{File.basename(fixture.path)}: header must say the live call returned no data rows"
      end
    end
    assert_empty failures, failures.join("\n  ")
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
    # Assert on the ATTRIBUTE mismatches specifically, and on the set of
    # positions rather than one-violation-per-position: when this fixture is
    # re-captured against a seeded box it becomes a live-capture, and
    # raw_type_violations will start adding :type_mismatch entries — several
    # at the same position — while the gate is still correctly flagging the
    # fabrication. (Copilot, #190.)
    mismatched = violations.select { |v| v.kind == :attribute_mismatch }
    # Positions 0-2 only. Position 3 is NOT a free pass for the fabrication —
    # it is a coincidence: the invented layout put a date at piece 4 and
    # FASTVIT really does carry the date/time taken there. (Against the
    # earlier, wrongly-cited VITALS^ORQQVI fixture this read as four
    # mismatches, which flattered the gate.) Three of four inventions caught
    # on shape alone; the fourth needs the type check over real rows — which
    # is exactly what a populated capture would add here.
    assert_equal [ 0, 1, 2 ], mismatched.map(&:position).uniq.sort,
                 "the fabricated TYPE^VALUE^UNITS^DATE layout must be flagged wherever it disagrees"
    refute_empty mismatched
    assert(violations.all? { |v| %i[attribute_mismatch type_mismatch].include?(v.kind) },
           "only shape and type disagreements are expected here")

    # ...and the corrected mapping (#188) passes the same gate.
    corrected = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:vitals], fixture)
    assert_empty corrected, corrected.join("; ")
  end

  def signed_on_as_required?(fixture)
    return false unless %w[live-capture no-data].include?(fixture.source)
    return true if CHART_READ_SLICE_MAPPINGS.include?(fixture.mapping_name)

    stamp = fixture.captured_at.to_s
    return false unless stamp.match?(/\A\d{4}-\d{2}-\d{2}/)

    stamp.byteslice(0, 10) >= SIGNED_ON_AS_INTRODUCED_ON.iso8601
  end
  private :signed_on_as_required?
end
