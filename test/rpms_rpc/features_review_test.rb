# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "socket"
require "rpms_rpc"
require_relative "features_test_helper"

# Gate round for rpms-rpc#511: golden expectations independent of features_test_helper's rule copy.
class FeaturesReviewTest < Minitest::Test
  include FeaturesTestHelper

  CONTEXTS_OOO_TAG = "features-review-contexts-ooo-ydb"
  OOO_OPTION_ONLY_TAG = "features-review-ooo-option-only-ydb"
  BROKER_EXEMPT_TAG = "features-review-broker-exempt-ydb"
  XUS_SIGNON_EXEMPT_TAG = "features-review-xus-signon-exempt-ydb"
  CACHE_ALIAS_TAG = "features-review-cache-alias-ydb"
  BROKEN_OPTION = "ZZ BROKEN OPTION"

  PINNED_REACH_FILE = File.join(PINNED_INVENTORIES, PINNED_TAG, "#{PINNED_TAG}-rpc_reach.txt")

  # Pin reach face (committed data): BEHO chart-banner RPCs are client-callable under CIAV VUECENTRIC only.
  PINNED_BEHOPTPC_GETBDP_REACH_LINE =
    "BEHOPTPC GETBDP^client-callable^1^1^CIAV VUECENTRIC^".freeze

  def setup
    features!.reset!
  end

  def teardown
    features!.reset!
  end

  # --- (1) Out-of-order option names in CONTEXTS must not count as served -------------------------

  def test_review_511_contexts_field_must_not_treat_out_of_order_option_as_served
    kw = { build: CONTEXTS_OOO_TAG, inventories_dir: FIXTURE_INVENTORIES }
    refute available?(:patient_chart_banner, **kw, context: BROKEN_OPTION),
           "an option named only by an out-of-order row must not serve the feature"
    assert available?(:patient_chart_banner, **kw, context: "CIAV VUECENTRIC")
  end

  def test_review_511_for_omits_session_feature_when_context_is_out_of_order_option
    listed = for_build(CONTEXTS_OOO_TAG, inventories_dir: FIXTURE_INVENTORIES, context: BROKEN_OPTION)
    refute_includes listed, :patient_chart_banner
  end

  def test_review_511_pin_ddr_lister_and_gets_entry_data_golden_document_scmc_ooo_option
    reach_lines = File.readlines(PINNED_REACH_FILE, chomp: true)
    lister = reach_lines.find { |line| line.start_with?("DDR LISTER^") }
    gets = reach_lines.find { |line| line.start_with?("DDR GETS ENTRY DATA^") }
    ooo_marker = reach_lines.find { |line| line.start_with?("SC DELETE ENTRY^") }

    assert_equal "DDR LISTER^client-callable^1^1^SCMC PCMM GUI WORKSTATION;CIAV VUECENTRIC;XU EPCS EDIT DATA^", lister
    assert_equal "DDR GETS ENTRY DATA^client-callable^1^1^SCMC PCMM GUI WORKSTATION;CIAV VUECENTRIC;XU EPCS EDIT DATA^", gets
    assert_equal "SC DELETE ENTRY^out-of-order^1^1^SCMC PCMM GUI WORKSTATION^", ooo_marker
  end

  def test_review_511_fixture_client_callable_only_under_out_of_order_named_option_is_not_served
    refute available?(:patient_chart_banner,
                      build: OOO_OPTION_ONLY_TAG,
                      inventories_dir: FIXTURE_INVENTORIES,
                      context: BROKEN_OPTION)
  end

  # --- (2) Golden pin answers; broker-exempt and XUS SIGNON must not count as served --------------

  def test_review_511_broker_exempt_rows_with_context_listed_are_not_served
    kw = { build: BROKER_EXEMPT_TAG, inventories_dir: FIXTURE_INVENTORIES, context: "CIAV VUECENTRIC" }
    refute available?(:patient_chart_banner, **kw)
    refute_includes for_build(BROKER_EXEMPT_TAG, inventories_dir: FIXTURE_INVENTORIES, context: "CIAV VUECENTRIC"),
                    :patient_chart_banner
  end

  def test_review_511_broker_exempt_rows_under_xus_signon_are_not_served
    kw = { build: XUS_SIGNON_EXEMPT_TAG, inventories_dir: FIXTURE_INVENTORIES, context: "XUS SIGNON" }
    refute available?(:patient_chart_banner, **kw)
    refute_includes for_build(XUS_SIGNON_EXEMPT_TAG, inventories_dir: FIXTURE_INVENTORIES, context: "XUS SIGNON"),
                    :patient_chart_banner
  end

  def test_review_511_pin_bmc_referral_workflow_available_without_context
    assert available?(:bmc_referral_workflow, build: PINNED_TAG)
  end

  def test_review_511_pin_patient_chart_banner_available_under_ciav_vuecentric
    assert available?(:patient_chart_banner, build: PINNED_TAG, context: "CIAV VUECENTRIC")
  end

  def test_review_511_pin_patient_chart_banner_not_available_under_or_cprs_gui_chart
    # BEHOPTPC GETBDP row lists CIAV VUECENTRIC only (see PINNED_BEHOPTPC_GETBDP_REACH_LINE).
    assert_includes File.readlines(PINNED_REACH_FILE, chomp: true), PINNED_BEHOPTPC_GETBDP_REACH_LINE
    refute available?(:patient_chart_banner, build: PINNED_TAG, context: "OR CPRS GUI CHART")
  end

  def test_review_511_pin_for_without_context_lists_only_bmc_referral_workflow
    assert_equal [ :bmc_referral_workflow ], for_build(PINNED_TAG)
  end

  # --- (3) Cache keyed by realpath: symlink alias must match real tag ------------------------------

  def test_review_511_symlinked_build_tag_matches_real_tag_cold_alias_first
    assert_symlink_alias_order_independent(:alias_first)
  end

  def test_review_511_symlinked_build_tag_matches_real_tag_real_tag_first
    assert_symlink_alias_order_independent(:real_first)
  end

  # --- (4) Malformed lock must raise ArgumentError, not Psych/Type errors -------------------------

  def test_review_511_malformed_lock_raises_argument_error_not_psych_syntax_error
    with_lock_path(malformed_lock_file("repo: [")) do
      assert_raises(ArgumentError) { features!.pinned_build_tags }
    end
  end

  def test_review_511_malformed_lock_releases_key_raises_argument_error_not_no_method_error
    with_lock_path(malformed_lock_file("releases: 3")) do
      assert_raises(ArgumentError) { features!.pinned_build_tags }
    end
  end

  def test_review_511_malformed_lock_scalar_list_raises_argument_error_not_type_error
    with_lock_path(malformed_lock_file("- a")) do
      assert_raises(ArgumentError) { features!.available?(:bmc_referral_workflow) }
    end
  end

  # --- (5) nil context: available? raises; for must raise too ------------------------------------

  def test_review_511_available_with_explicit_nil_context_raises_argument_error
    assert_raises(ArgumentError) do
      features!.available?(:patient_chart_banner, build: PINNED_TAG, context: nil)
    end
  end

  def test_review_511_for_with_nil_context_raises_argument_error
    assert_raises(ArgumentError) do
      features!.for(build: PINNED_TAG, context: nil)
    end
  end

  def test_review_511_for_without_context_keyword_still_lists_fixed_context_features
    assert_equal [ :bmc_referral_workflow ], features!.for(build: PINNED_TAG)
  end

  # --- (6) Inventory-only guard: no broker sockets -----------------------------------------------

  def test_review_511_pin_features_never_open_sockets
    with_inventory_only_guard do
      assert available?(:bmc_referral_workflow, build: PINNED_TAG)
      assert available?(:patient_chart_banner, build: PINNED_TAG, context: "CIAV VUECENTRIC")
      assert available?(:orqqpl_problem_workflow, build: PINNED_TAG, context: "OR CPRS GUI CHART")
      assert_equal [ :bmc_referral_workflow ], for_build(PINNED_TAG)
      for_build(PINNED_TAG, context: "CIAV VUECENTRIC")
      for_build(PINNED_TAG, context: "OR CPRS GUI CHART")
    end
  end

  def test_review_511_inventory_only_guard_sanity_fires_on_tcp_socket
    fired = false
    with_inventory_only_guard do
      begin
        TCPSocket.new("127.0.0.1", 1)
      rescue StandardError => e
        fired = true
        assert_match(/features review 511 network guard/i, e.message)
      end
    end
    assert fired, "guard must intercept TCPSocket.new"
  end

  private

  def assert_symlink_alias_order_independent(order)
    Dir.mktmpdir("features-review-cache-") do |tmpdir|
      real_tag = REACH_OK_TAG
      copy_inventory_tag_to_tmpdir(tmpdir, real_tag, from_dir: FIXTURE_INVENTORIES)
      File.symlink(File.join(tmpdir, real_tag), File.join(tmpdir, CACHE_ALIAS_TAG))

      kw = { inventories_dir: tmpdir, context: "CIAV VUECENTRIC" }

      features!.reset!
      golden = available?(:patient_chart_banner, build: real_tag, **kw)

      features!.reset!
      alias_answer =
        case order
        when :alias_first
          available?(:patient_chart_banner, build: CACHE_ALIAS_TAG, **kw)
        when :real_first
          available?(:patient_chart_banner, build: real_tag, **kw)
          available?(:patient_chart_banner, build: CACHE_ALIAS_TAG, **kw)
        end

      assert_equal golden, alias_answer
    end
  end

  def malformed_lock_file(body)
    path = File.join(Dir.mktmpdir("features-review-lock-"), "rpms-ops.lock.yml")
    File.write(path, body)
    path
  end

  def with_lock_path(path)
    feat = features!
    original = RpmsRpc::Features::LOCK_PATH
    RpmsRpc::Features.send(:remove_const, :LOCK_PATH)
    RpmsRpc::Features.const_set(:LOCK_PATH, path)
    feat.reset!
    yield
  ensure
    RpmsRpc::Features.send(:remove_const, :LOCK_PATH)
    RpmsRpc::Features.const_set(:LOCK_PATH, original)
    feat.reset!
  end

  GUARD_MESSAGE = "Features review 511 network guard"

  def with_inventory_only_guard
    originals = nil
    client_original = nil
    broker_client = Class.new do
      def call_rpc(*)
        raise FeaturesReviewTest::GUARD_MESSAGE
      end

      def method_missing(*)
        raise FeaturesReviewTest::GUARD_MESSAGE
      end

      def respond_to_missing?(*) = true
    end.new

    guarded = proc { |*_args, **_kw, &_block| raise GUARD_MESSAGE }
    socket_methods = [ [ TCPSocket, :new ], [ Socket, :new ], [ UNIXSocket, :new ] ]
    socket_methods << [ Socket, :tcp ] if Socket.respond_to?(:tcp)
    originals = socket_methods.to_h { |klass, name| [ [ klass, name ], klass.method(name) ] }

    originals.each_key do |klass, name|
      klass.define_singleton_method(name, guarded)
    end
    client_original = RpmsRpc.method(:client)
    RpmsRpc.define_singleton_method(:client) { broker_client }
    yield
  ensure
    originals&.each do |(klass, name), original|
      klass.define_singleton_method(name, original)
    end
    RpmsRpc.define_singleton_method(:client, client_original) if client_original
  end
end
