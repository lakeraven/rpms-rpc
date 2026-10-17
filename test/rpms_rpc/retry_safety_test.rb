# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "json"
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

  # --- auto_retry_safe? ------------------------------------------------------

  def test_only_reads_are_auto_retry_safe
    assert RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Patient, :find)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Referral, :create)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Procedure, :delete)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Agg, :add_patient)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Patient, :__unknown_retry_safety_method__)
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
      assert_equal :read, RpmsRpc::RetrySafety.for(mod, name),
                   "#{method_label(mod, name)} must be classified :read for this test"

      RpmsRpc.mock! do |m|
        seed.call(m)
        mod.public_send(name, *args)
        write_calls = RpmsRpc.client.received_calls.select { |c| write_rpc?(c[:rpc]) }
        assert_empty write_calls,
                     "#{method_label(mod, name)} issued write RPCs: #{write_calls.map { |c| c[:rpc] }.join(", ")}"
      end
    ensure
      RpmsRpc.reset!
    end
  end
end
