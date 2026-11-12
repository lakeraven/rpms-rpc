# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "yaml"
require "rpms_rpc/wire_capture"

# Fixture names for wire captures (#700, a slice of #566).
#
# A capture fixture file used to be named by its RPC slug, and compare, ONLY
# and CITE_ONLY keyed on the RPC name, so two catalog entries calling one RPC
# with different inputs overwrote each other. A CatalogEntry may now carry
# its own fixture: name; everything that selects or names a capture goes
# through that name.
#
# The catalog here is synthetic and built in the test: no entry is added to
# the real CATALOG.
class RpmsRpc::WireCaptureFixtureNameTest < Minitest::Test
  WC = RpmsRpc::WireCapture
  SHARED_RPC = "DDR GETS ENTRY DATA"
  OTHER_RPC = "ORWPT SELECT"
  CITED_RPC = "SYNTHETIC CITED RPC"
  WRITE_RPC = "SYNTHETIC WRITE RPC"

  def slug(rpc) = rpc.downcase.tr(" /", "--")

  def entry(rpc:, mode: :live, **rest)
    WC::CatalogEntry.new(rpc: rpc, mapping: :synthetic, kind: "fields", mode: mode,
                         inputs: mode == :routine_cite ? nil : [ "1" ],
                         cite: "synthetic", pieces: [], **rest)
  end

  # Built per test, so a missing fixture: keyword fails each test that needs
  # it instead of the whole file at load.
  def shared_slug = @shared_slug ||= entry(rpc: SHARED_RPC)
  def shared_named = @shared_named ||= entry(rpc: SHARED_RPC, fixture: "synthetic-second")
  def other = @other ||= entry(rpc: OTHER_RPC)
  def cited = @cited ||= entry(rpc: CITED_RPC, mode: :routine_cite)
  def write = @write ||= entry(rpc: WRITE_RPC, mode: :write)
  def catalog = [ shared_slug, shared_named, other, cited, write ]

  # -- CatalogEntry#fixture_name / #named? ----------------------------------

  def test_fixture_name_defaults_to_the_rpc_slug
    assert_equal "orqqvi-vitals", entry(rpc: "ORQQVI VITALS").fixture_name
    assert_equal "a-b-c", entry(rpc: "A/B C").fixture_name
  end

  def test_fixture_name_is_the_given_fixture
    assert_equal "synthetic-second", shared_named.fixture_name
    assert_equal SHARED_RPC, shared_named.rpc
    assert_equal "ddr-gets-entry-data", shared_slug.fixture_name
  end

  def test_named_matches_the_rpc_name_or_the_fixture_name
    assert shared_named.named?(SHARED_RPC)
    assert shared_named.named?("synthetic-second")
    refute shared_named.named?("ddr-gets-entry-data"), "the slug is not this entry's fixture name"
    refute shared_named.named?(OTHER_RPC)

    assert shared_slug.named?(SHARED_RPC)
    assert shared_slug.named?("ddr-gets-entry-data")
    refute shared_slug.named?("synthetic-second")
  end

  # CATALOG today has no two entries for one RPC (checked when this was
  # written), so uniqueness of fixture names holds across the whole catalog
  # and every entry's file name is its RPC slug, as before.
  def test_every_catalog_entry_keeps_its_rpc_slug_file_name
    refute_empty WC::CATALOG
    assert_equal WC::CATALOG.map(&:rpc).uniq, WC::CATALOG.map(&:rpc), "premise: one CATALOG entry per RPC"

    names = WC::CATALOG.map(&:fixture_name)
    assert_equal WC::CATALOG.map { |e| slug(e.rpc) }, names
    assert_equal names.uniq, names, "fixture names must be unique across CATALOG"
    WC::CATALOG.each do |e|
      assert File.exist?(WC.fixture_path(e)), "no committed fixture at #{WC.fixture_path(e)}"
    end
  end

  # -- fixture_path ----------------------------------------------------------

  def test_fixture_path_is_the_fixture_name_under_fixtures_dir
    assert_equal File.join(WC::FIXTURES_DIR, "ddr-gets-entry-data.yml"), WC.fixture_path(shared_slug)
    assert_equal File.join(WC::FIXTURES_DIR, "synthetic-second.yml"), WC.fixture_path(shared_named)
    refute_equal WC.fixture_path(shared_slug), WC.fixture_path(shared_named)
  end

  # -- cite_only? / unmatched_cite_only_tokens -------------------------------

  def test_cite_only_by_rpc_name_cites_only_the_slug_entry
    tokens = [ SHARED_RPC ]
    assert WC.cite_only?(shared_slug, tokens)
    refute WC.cite_only?(shared_named, tokens), "an entry with its own fixture: is not cited by the shared RPC name"
    refute WC.cite_only?(other, tokens)
  end

  def test_cite_only_by_fixture_name_cites_that_entry_alone
    assert WC.cite_only?(shared_named, [ "synthetic-second" ])
    refute WC.cite_only?(shared_slug, [ "synthetic-second" ])

    assert WC.cite_only?(shared_slug, [ "ddr-gets-entry-data" ])
    refute WC.cite_only?(shared_named, [ "ddr-gets-entry-data" ])

    assert WC.cite_only?(other, [ "NOT THIS", OTHER_RPC ]), "any one matching token cites"
    refute WC.cite_only?(other, [])
  end

  def test_unmatched_cite_only_tokens_keeps_input_order_without_duplicates
    live = catalog.select(&:live?)
    assert_equal [ "SYNTHETIC NOPE", "also-nope" ],
                 WC.unmatched_cite_only_tokens(
                   live, [ "SYNTHETIC NOPE", "synthetic-second", "also-nope", SHARED_RPC, "SYNTHETIC NOPE" ]
                 )
    assert_equal [ CITED_RPC ], WC.unmatched_cite_only_tokens(live, [ OTHER_RPC, CITED_RPC ]),
                 "a token naming only a non-live entry is unmatched against the live entries"
    assert_equal [], WC.unmatched_cite_only_tokens(live, [ "synthetic-second", SHARED_RPC, "orwpt-select" ])
  end

  # -- select_live_entries ---------------------------------------------------

  def test_select_live_entries_is_the_live_entries_of_the_catalog
    assert_equal [ shared_slug, shared_named, other ], WC.select_live_entries(catalog: catalog)
  end

  def test_select_live_entries_defaults_to_the_real_catalog
    expected = WC::CATALOG.select(&:live?)
    refute_empty expected
    assert_equal expected, WC.select_live_entries
  end

  def test_select_live_entries_only_matches_rpc_name_or_fixture_name
    assert_equal [ shared_slug, shared_named ], WC.select_live_entries(catalog: catalog, only: SHARED_RPC)
    assert_equal [ shared_named ], WC.select_live_entries(catalog: catalog, only: "synthetic-second")
    assert_equal [ shared_slug ], WC.select_live_entries(catalog: catalog, only: "ddr-gets-entry-data")
    assert_equal [ other ], WC.select_live_entries(catalog: catalog, only: "orwpt-select")
  end

  def test_select_live_entries_removes_cite_only_entries
    assert_equal [ shared_named, other ],
                 WC.select_live_entries(catalog: catalog, cite_only: [ SHARED_RPC ])
    assert_equal [ shared_slug, other ],
                 WC.select_live_entries(catalog: catalog, cite_only: [ "synthetic-second" ])
    assert_equal [ shared_named ],
                 WC.select_live_entries(catalog: catalog, only: SHARED_RPC, cite_only: [ SHARED_RPC ])
  end

  def test_select_live_entries_raises_naming_each_unmatched_token
    entries = catalog # built outside the block: its own ArgumentError must not satisfy assert_raises
    error = assert_raises(ArgumentError) do
      WC.select_live_entries(catalog: entries, cite_only: [ "SYNTHETIC NOPE", OTHER_RPC, "also-nope" ])
    end
    assert_includes error.message, "SYNTHETIC NOPE".inspect
    assert_includes error.message, "also-nope".inspect
    refute_includes error.message, OTHER_RPC.inspect
  end

  def test_select_live_entries_treats_a_token_for_a_non_live_entry_as_unmatched
    entries = catalog
    [ cited, write ].each do |non_live|
      [ non_live.rpc, slug(non_live.rpc) ].each do |token|
        error = assert_raises(ArgumentError, "token #{token.inspect}") do
          WC.select_live_entries(catalog: entries, cite_only: [ token ])
        end
        assert_includes error.message, token.inspect
      end
    end
  end

  # ONLY narrows after the tokens are judged: a token for a real live fixture
  # that ONLY happens to exclude is not an error.
  def test_select_live_entries_judges_tokens_before_only_narrows
    assert_equal [ other ],
                 WC.select_live_entries(catalog: catalog, only: OTHER_RPC, cite_only: [ "synthetic-second" ])

    entries = catalog
    error = assert_raises(ArgumentError) do
      WC.select_live_entries(catalog: entries, only: OTHER_RPC, cite_only: [ "SYNTHETIC NOPE" ])
    end
    assert_includes error.message, "SYNTHETIC NOPE".inspect
  end

  # -- fixture_entries -------------------------------------------------------

  def test_fixture_entries_only_matches_a_fixture_name
    assert_equal [ "ORQQVI VITALS" ], WC.fixture_entries(writes: false, only: "orqqvi-vitals").map(&:rpc)
    assert_equal [ "ORQQVI VITALS" ], WC.fixture_entries(writes: false, only: "ORQQVI VITALS").map(&:rpc)
    assert_equal [ "TIU SIGN RECORD" ], WC.fixture_entries(writes: true, only: "tiu-sign-record").map(&:rpc)
  end

  # -- Fixture#fixture_name --------------------------------------------------

  def test_a_loaded_fixture_is_named_by_its_file_basename
    committed = File.join(WC::FIXTURES_DIR, "orwpt-select.yml")
    assert_equal "orwpt-select", WC::Fixture.load_file(committed).fixture_name

    Dir.mktmpdir("wire-fixture-name") do |dir|
      copy = File.join(dir, "synthetic-second.yml")
      FileUtils.cp(committed, copy)
      loaded = WC::Fixture.load_file(copy)
      assert_equal "ORWPT SELECT", loaded.rpc
      assert_equal "synthetic-second", loaded.fixture_name

      assert_equal [ "synthetic-second" ], WC::Fixture.load_all(dir).map(&:fixture_name)
    end
  end

  def test_an_in_memory_fixture_has_no_fixture_name
    data = YAML.safe_load_file(File.join(WC::FIXTURES_DIR, "orwpt-select.yml"))
    fixture = WC::Fixture.new(data)
    assert_equal "ORWPT SELECT", fixture.rpc
    assert_nil fixture.path
    assert_respond_to fixture, :fixture_name
    assert_nil fixture.fixture_name
  end

  # -- rake task and driver (light source checks; the behavior is above) -----

  def test_the_capture_task_checks_cite_only_tokens_and_writes_at_fixture_path
    src = File.read(File.expand_path("../../lib/tasks/wire.rake", __dir__), encoding: "UTF-8")
    assert_match(/\bunmatched_cite_only_tokens\b/, src,
                 "wire:capture must abort on a CITE_ONLY token matching no live entry")
    assert_match(/\bfixture_path\b/, src, "wire:capture must write each fixture at fixture_path(entry)")
  end

  def test_the_driver_selects_and_keys_captures_by_fixture_name
    src = File.read(File.expand_path("../../bin/wire_capture_driver.rb", __dir__), encoding: "UTF-8")
    assert_match(/\b(?:select_live_entries|driver_read_entries)\b/, src)
    assert_match(/\bfixture_name\b/, src, "the driver must key captures and selected by fixture_name")
  end
end
