# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "json"
require "psych"
require "tmpdir"
require "rpms_rpc"
require_relative "../../tools/api_coverage/api_coverage"

# rpms-rpc#110: retry-safety classification table, lint surface, and acceptance gates.
# Implementation lives in lib/rpms_rpc/retry_safety.rb and lib/rpms_rpc/retry_safety.yml.
class RpmsRpc::RetrySafetyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  API_DIR = File.join(ROOT, "lib/rpms_rpc/api")
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  # Mutating RPC name shapes the gem must never classify as :read (by static RPC resolution).
  # EDIT CHECK / EDIT LOAD stay in: they are edit-family RPCs even when used as read helpers.
  WRITE_RPC_PATTERN = /
    \bFILER\b |
    \bDELETE\b |
    \bDEL\b |
    \bSAVE\b |
    \bADD\b |
    \bSET\b |
    \bUPDATE\b |
    \bCREATE\b |
    \bEDIT\b |
    \bLOCK\b |
    \bUNLOCK\b |
    \bSIGN\b |
    \bUNSIGN\b |
    \bCANCEL\b |
    \bUNCANCEL\b |
    \bCHECKIN\b |
    \bNOSHOW\b |
    \bINACTIVATE\b |
    \bVERIFY\b |
    STATUS\ UPDATE |
    PRINT\ LOG |
    \AXUS\ AV\ CODE\z |
    \AXUS\ CVC\z |
    TIU\ SET\ DOCUMENT\ TEXT
  /ix

  # Representative write RPCs shipped in required_rpcs.json — the pattern must not be vacuous.
  EXPLICIT_WRITE_RPC_SAMPLES = [
    "DDR FILER",
    "TIU DELETE RECORD",
    "TIU SET DOCUMENT TEXT",
    "AGG ADD NEW PATIENT",
    "AGG UPDATE PATIENT",
    "BEHOVM SAVE",
    "BMC ADD REFERRAL",
    "BMC CONSULTATION STATUS UPDATE",
    "BSDX CANCEL APPOINTMENT",
    "BSDX CHECKIN APPOINTMENT",
    "BSDX NOSHOW",
    "ORQQPL EDIT LOAD",
    "ORQQPL INACTIVATE",
    "ORQQPL VERIFY",
    "XUS AV CODE",
    "XUS CVC"
  ].freeze

  MOCK_READ_CALLS = [
    {
      mod: RpmsRpc::Patient,
      method: :find,
      args: [ 1 ],
      seed: lambda do |m|
        m.seed(:patient_select, "1", {
          name: "DOE,SYNTH", sex: "M", dob: Date.new(1980, 1, 15),
          ssn: "000000001", age: 45
        })
      end
    },
    {
      mod: RpmsRpc::Allergy,
      method: :for_patient,
      args: [ 1 ],
      seed: lambda do |m|
        m.seed_collection(:allergy_list, [
          { ien: 1, allergen: "SYNTH-ALLERGEN", severity: "MODERATE", signs: "SYNTH-SIGNS" }
        ])
      end
    },
    {
      mod: RpmsRpc::Procedure,
      method: :for_patient,
      args: [ 1 ],
      seed: lambda do |m|
        m.seed_collection(:procedure_list, [
          {
            ien: 1, visit_ien: 10, date: "01/15/2026", cpt_code: "99213",
            cpt_name: "OFFICE VISIT", name: "OFFICE VISIT", diagnosis: "",
            modifier_1: "", modifier_2: "", quantity: 1, provider: "PROV,SYNTH",
            facility: "SYNTH CLINIC"
          }
        ])
      end
    }
  ].freeze

  def api_method_pairs
    @api_method_pairs ||= ApiCoverage.public_methods_of(RpmsRpc, API_DIR)
  end

  def resolver
    @resolver ||= ApiCoverage::Resolver.new(
      lib_dir: File.join(ROOT, "lib"),
      mappings: ApiCoverage.mapping_rpcs
    )
  end

  def required_rpc_names
    @required_rpc_names ||= begin
      doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
      doc.fetch("modules").values.flatten.uniq
    end
  end

  def method_label(mod, name) = "#{mod.name}.#{name}"

  def write_rpc?(name) = name.match?(WRITE_RPC_PATTERN)

  # --- table path / gemspec --------------------------------------------------

  def test_retry_safety_table_path_lives_under_lib_and_is_shipped_in_the_gem
    path = File.expand_path(RpmsRpc::RetrySafety::PATH, ROOT)
    lib_root = File.join(ROOT, "lib")

    assert path.start_with?("#{lib_root}/"), "PATH must be under lib/: #{path}"
    assert path.end_with?("rpms_rpc/retry_safety.yml"), "PATH must be lib/rpms_rpc/retry_safety.yml"

    rel = path.delete_prefix("#{ROOT}/")
    files = Gem::Specification.load(File.join(ROOT, "rpms-rpc.gemspec")).files
    assert_includes files, rel, "retry_safety.yml must be listed in rpms-rpc.gemspec files"
  end

  # --- coverage of the public API --------------------------------------------

  def test_every_public_api_method_is_classified
    omissions = api_method_pairs.filter_map do |mod, name|
      label = method_label(mod, name)
      begin
        cls = RpmsRpc::RetrySafety.for(mod, name)
        label unless RpmsRpc::RetrySafety::CLASSES.include?(cls)
      rescue KeyError
        label
      end
    end

    assert_empty omissions,
                 "every public API method must appear in retry_safety.yml:\n#{omissions.sort.join("\n")}"
  end

  def test_no_stale_entries
    stale = RpmsRpc::RetrySafety.table.keys.sort.filter_map do |key|
      mod_name, method_name = key.split(".", 2)
      mod = mod_name.split("::").reduce(Object) { |ns, part| ns.const_get(part) }
      pair = [ mod, method_name.to_sym ]
      key unless api_method_pairs.include?(pair)
    rescue NameError
      key
    end

    assert_empty stale, "stale retry_safety.yml keys (no longer a public API method):\n#{stale.join("\n")}"
  end

  def test_no_idempotent_writes_without_proof
    count = RpmsRpc::RetrySafety.table.values.count { |v| v == :idempotent_write }
    assert_equal 0, count, "no :idempotent_write entries until dedupe is proven in code"
  end

  # --- RetrySafety.for / .table / .load --------------------------------------

  def test_unclassified_method_raises_keyerror_naming_it
    error = assert_raises(KeyError) do
      RpmsRpc::RetrySafety.for(RpmsRpc::Patient, :__retry_safety_missing_method__)
    end
    assert_match(/__retry_safety_missing_method__/, error.message)
  end

  def test_for_accepts_module_or_name_and_method_as_symbol_or_string
    assert_equal RpmsRpc::RetrySafety.for(RpmsRpc::Patient, :find),
                 RpmsRpc::RetrySafety.for("RpmsRpc::Patient", "find")
  end

  def test_table_returns_a_frozen_hash_of_string_keys_to_symbols
    table = RpmsRpc::RetrySafety.table
    assert_kind_of Hash, table
    assert table.frozen?
    refute_empty table
    each_keys = []
    table.each do |key, value|
      assert_match(/\ARpmsRpc::.+?\.\w+[?!=]?\z/, key)
      assert_kind_of Symbol, value
      assert_includes RpmsRpc::RetrySafety::CLASSES, value
      each_keys << key
    end

    api_method_pairs.each do |mod, name|
      key = method_label(mod, name)
      assert_includes table.keys, key
      assert_includes each_keys, key
    end
  end

  # RetrySafety.load(path) is the public entry for parsing a YAML table; invalid values must fail loudly.
  def test_load_rejects_unknown_classification_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, "RpmsRpc::Patient.find: imaginary_class\n")
      error = assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
      assert_match(/RpmsRpc::Patient\.find/, error.message)
      assert_match(/imaginary_class/, error.message)
    end
  end

  def test_load_raises_on_duplicate_top_level_keys
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, <<~YAML)
        "RpmsRpc::Patient.find": read
        "RpmsRpc::Patient.find": non_idempotent_write
      YAML
      error = assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
      assert_match(/RpmsRpc::Patient\.find/, error.message)
    end
  end

  def test_committed_retry_safety_yml_has_unique_sorted_top_level_keys
    path = File.expand_path(RpmsRpc::RetrySafety::PATH, ROOT)
    mapping = Psych.parse_file(path).children.find { |c| c.is_a?(Psych::Nodes::Mapping) }
    keys = mapping.children.each_with_index.filter_map do |node, i|
      node.value if i.even? && node.is_a?(Psych::Nodes::Scalar)
    end

    assert_equal keys.size, keys.uniq.size, "duplicate top-level keys in #{path}"
    assert_equal keys, keys.sort, "top-level keys must be sorted in #{path}"
  end

  def test_load_raises_on_malformed_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, "key: [\n")
      assert_raises(Psych::SyntaxError, ArgumentError) { RpmsRpc::RetrySafety.load(path) }
    end
  end

  def test_load_raises_when_file_is_missing
    path = File.join(Dir.mktmpdir, "missing_retry_safety.yml")
    assert_raises(Errno::ENOENT) { RpmsRpc::RetrySafety.load(path) }
  end

  def test_load_raises_when_document_is_not_a_hash
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, "plain string document\n")
      error = assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
      assert_match(/not a Hash/i, error.message)
    end
  end

  def test_load_raises_on_empty_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, "")
      assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
    end
  end

  def test_load_raises_on_non_string_key
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, <<~YAML)
        1: read
      YAML
      error = assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
      assert_match(/not a String key/i, error.message)
    end
  end

  def test_load_raises_on_non_string_classification_value
    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, <<~YAML)
        "RpmsRpc::Patient.find": 1
      YAML
      error = assert_raises(ArgumentError) { RpmsRpc::RetrySafety.load(path) }
      assert_match(/RpmsRpc::Patient\.find/, error.message)
    end
  end

  # --- RetrySafety.lint ------------------------------------------------------

  def test_lint_reports_unclassified_labels_and_stale_table_keys
    table = { "RpmsRpc::Synth::A.m" => :read }
    labels = [ "RpmsRpc::Synth::A.m", "RpmsRpc::Synth::B.m" ]
    result = RpmsRpc::RetrySafety.lint(labels, table)
    assert_equal [ "RpmsRpc::Synth::B.m" ], result[:unclassified]
    assert_empty result[:stale]

    table_with_stale = table.merge("RpmsRpc::Synth::Stale.m" => :read)
    result = RpmsRpc::RetrySafety.lint([ "RpmsRpc::Synth::A.m" ], table_with_stale)
    assert_empty result[:unclassified]
    assert_equal [ "RpmsRpc::Synth::Stale.m" ], result[:stale]

    clean = RpmsRpc::RetrySafety.lint([ "RpmsRpc::Synth::A.m" ], table)
    assert_empty clean[:unclassified]
    assert_empty clean[:stale]
  end

  def test_lint_is_clean_for_current_public_api_and_committed_table
    labels = api_method_pairs.map { |mod, name| method_label(mod, name) }
    result = RpmsRpc::RetrySafety.lint(labels, RpmsRpc::RetrySafety.table)
    assert_empty result[:unclassified]
    assert_empty result[:stale]
  end

  # --- auto_retry_safe? ------------------------------------------------------

  def test_only_reads_are_auto_retry_safe
    assert RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Patient, :find)

    [
      [ RpmsRpc::Referral, :create ],
      [ RpmsRpc::Problem, :delete ],
      [ RpmsRpc::Agg, :add_patient ],
      [ RpmsRpc::Encounter, :create ]
    ].each do |mod, name|
      assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(mod, name),
                   "#{method_label(mod, name)} must be :non_idempotent_write"
      refute RpmsRpc::RetrySafety.auto_retry_safe?(mod, name),
             "#{method_label(mod, name)} must not be auto-retry-safe"
    end

    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Patient, :__unknown_retry_safety_method__)
  end

  # DdrFileman.lister passes caller-supplied SCREEN and ID into LIST^DIC as M code,
  # so a retry can repeat a side effect. Notifications.inbox uses BQI GET COMM ALERTS
  # SPLASH; mapping is best-effort pending trace capture and a splash read may record
  # that alerts were shown.
  def test_fail_closed_when_code_does_not_establish_read_only_effect
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::DdrFileman, :lister)
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Notifications, :inbox)
  end

  # --- static RPC resolution vs classification -------------------------------

  def test_explicit_write_rpc_samples_exist_in_required_rpcs_json
    missing = EXPLICIT_WRITE_RPC_SAMPLES.reject { |name| required_rpc_names.include?(name) }
    assert_empty missing,
                 "write-RPC samples must be real gem RPCs (required_rpcs.json):\n#{missing.join("\n")}"

    unmapped = EXPLICIT_WRITE_RPC_SAMPLES.reject { |name| write_rpc?(name) }
    assert_empty unmapped, "WRITE_RPC_PATTERN must cover every sample:\n#{unmapped.join("\n")}"
  end

  def test_methods_sending_write_rpcs_are_never_read
    violations = api_method_pairs.filter_map do |mod, name|
      rpcs = resolver.resolve(mod, name)[:rpcs].map { |r| r[:name] }
      next if rpcs.none? { |rpc| write_rpc?(rpc) }

      cls = RpmsRpc::RetrySafety.for(mod, name)
      next if cls != :read

      rpcs.select { |rpc| write_rpc?(rpc) }.map { |rpc| "  #{method_label(mod, name)} (#{rpc})" }
    end.flatten

    assert_empty violations,
                 "methods whose RPCs match WRITE_RPC_PATTERN must not be :read:\n#{violations.sort.join("\n")}"
  end

  # --- mock client wire evidence for :read methods ----------------------------

  def test_classification_follows_the_mock_client
    MOCK_READ_CALLS.each do |spec|
      mod, name, args, seed = spec.values_at(:mod, :method, :args, :seed)
      label = method_label(mod, name)
      assert_equal :read, RpmsRpc::RetrySafety.for(mod, name),
                   "#{label} must be classified :read for this test"
      expected_rpcs = resolver.resolve(mod, name)[:rpcs].map { |r| r[:name] }

      RpmsRpc.mock! do |m|
        seed.call(m)
        mod.public_send(name, *args)
        calls = RpmsRpc.client.received_calls
        refute_empty calls, "#{label} must send at least one RPC on the mock client"
        received_rpc_names = calls.map { |c| c[:rpc] }
        expected_rpcs.each do |rpc|
          assert_includes received_rpc_names, rpc,
                          "#{label} must send #{rpc} (static ApiCoverage resolver)"
        end
        write_calls = calls.select { |c| write_rpc?(c[:rpc]) }
        assert_empty write_calls,
                     "#{label} issued write RPCs: #{write_calls.map { |c| c[:rpc] }.join(", ")}"
      end
    ensure
      RpmsRpc.reset!
    end
  end
end
