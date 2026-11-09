# frozen_string_literal: true

require "minitest/autorun"
require "delegate"
require "json"
require "rpms_rpc"
require "rpms_rpc/mappings"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/retry_safety"
require_relative "../../captured_replies"

# AMHG SAVE HEALTH FACTORS: HF^AMHGSVF (AMHGSVF.m:277-305), MODHF/DELHF^AMHGEVF.
#
# The guard and refusal cases, read from replies the pinned build sent
# (test/fixtures/captured_replies/amhg-save-health-factors.yml): one edit-mode
# save of one health factor on a BH visit for synthetic patient DFN 990037,
# captured in the gem's call order, and the refusals the build sends (a lock
# another session holds, an inactive, category or unknown health factor name,
# AMHG's error reply). Replayed through CiaClient per ADR 0009. The round trip
# itself is proven by test/live/behavioral_health_save_health_factors_live_test.rb
# (rpms-rpc#622, option b).
class BehavioralHealthSaveHealthFactorsTest < Minitest::Test
  BH = RpmsRpc::BehavioralHealth
  SLUG = "amhg-save-health-factors"
  RPC = "AMHG SAVE HEALTH FACTORS"
  DDR_LOCK = "DDR LOCK/UNLOCK NODE"
  DDR_GETS = "DDR GETS ENTRY DATA"
  DDR_LISTER = "DDR LISTER"
  HF_FILE = "9002011.08"
  HF_TYPE_FILE = "9999999.64"
  FILEMAN_CONTEXT = RpmsRpc::Patient::FILEMAN_CONTEXT

  ROOT = File.expand_path("../../../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  RPCS_MD_PATH = File.join(ROOT, "docs/rpcs.md")
  MAPPINGS_PATH = File.join(ROOT, "lib/rpms_rpc/mappings/ihs.rb")

  def self.capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  SAVE_WIRE = capture("save").fetch("inputs").first
  RECORD_IEN, NAME_AND_VALUES, PATIENT = SAVE_WIRE.split("|", -1).values_at(1, 2, 3)
  HF_NAME = NAME_AND_VALUES.split("~").first
  OTHER_PATIENT = "990045"

  # A replay client that also notes the option each RPC ran under.
  class ContextReplay < CapturedReplies::ReplayCiaClient
    def call_rpc_raw(rpc_name, *params)
      super.tap { @calls.last[:context] = current_context }
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def raw(name) = CapturedReplies.raw(SLUG, name)

  # The captured conversation of one save; any capture can stand in for one
  # step (say, the busy lock for the lock).
  def replay(lock: "lock", visit: "visit", type: "type_active", save: "save", readback: "readback")
    @client = ContextReplay.new(
      DDR_LOCK => [ raw(lock), raw("unlock") ],
      DDR_GETS => [ raw(visit) ],
      DDR_LISTER => [ raw(type), raw(readback) ],
      RPC => [ raw(save) ]
    )
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def factor(**overrides)
    { name: HF_NAME, level: "MINIMAL", quantity: "1", comment: "SYN HF" }.merge(overrides)
  end

  def kwargs(**overrides)
    { record_ien: RECORD_IEN, patient: PATIENT, mode: :edit, health_factors: [ factor ] }.merge(overrides)
  end

  def rpcs = @client.calls.map { |c| c[:rpc] }
  def amhg_calls = @client.calls.select { |c| c[:rpc] == RPC }
  def lock_calls = @client.calls.select { |c| c[:rpc] == DDR_LOCK && c[:params].first.key?("LOCKMODE") }
  def unlock_calls = @client.calls.select { |c| c[:rpc] == DDR_LOCK && !c[:params].first.key?("LOCKMODE") }

  def assert_refused_before_write(pattern = nil, **args)
    err = assert_raises(BH::SaveError) { BH.save_health_factors(**args) }
    assert_match pattern, err.message if pattern
    assert_empty amhg_calls, "nothing may reach #{RPC}"
    err
  end

  # --- the captured save ------------------------------------------------------

  def test_the_captured_save_returns_the_record_ien
    replay

    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)
  end

  def test_the_save_sends_the_wire_the_build_filed
    replay
    BH.save_health_factors(**kwargs)

    assert_equal [ SAVE_WIRE ], amhg_calls.first[:params]
  end

  # The record is locked across the visit pre-read, the type pre-read, the
  # write and the read-back.
  def test_lock_pre_reads_write_readback_and_unlock_run_in_order
    replay
    BH.save_health_factors(**kwargs)

    assert_equal [ DDR_LOCK, DDR_GETS, DDR_LISTER, RPC, DDR_LISTER, DDR_LOCK ], rpcs.grep(String)
    assert_includes @client.calls[2][:params].first["FILE"], HF_TYPE_FILE
    assert_includes @client.calls.select { |c| c[:rpc] == DDR_LISTER }.last[:params].first["FILE"], HF_FILE
  end

  def test_the_write_runs_under_amhgrpc_and_the_fileman_calls_under_the_fileman_context
    replay
    caller_context = @client.current_context
    BH.save_health_factors(**kwargs)

    assert_equal "AMHGRPC", amhg_calls.first[:context]
    @client.calls.select { |c| c[:rpc].is_a?(String) && c[:rpc] != RPC }.each do |call|
      assert_equal FILEMAN_CONTEXT, call[:context], "#{call[:rpc]} must run under the FileMan context"
    end
    assert_equal caller_context, @client.current_context
  end

  # --- refusals the build sends -----------------------------------------------

  def test_a_lock_another_session_holds_is_refused_before_any_read_or_write
    replay(lock: "lock_held_elsewhere")

    err = assert_refused_before_write(/was not acquired/i, **kwargs)

    refute_match(/may have been filed|outcome unknown/i, err.message, "nothing was sent, so the outcome is known")
    assert_empty(@client.calls.select { |c| c[:rpc] == DDR_GETS })
    assert_equal 1, unlock_calls.length, "a sent, unacquired lock is released"
  end

  def test_an_inactive_health_factor_is_refused_and_unlocked
    replay(type: "type_inactive")

    assert_refused_before_write(**kwargs(health_factors: [ factor(name: "0-FOOD AND EXERCISE") ]))
    assert_equal 1, unlock_calls.length
  end

  # The B pre-read for "4PS" lists the CATEGORY 4PS and the longer FACTOR
  # names it prefixes: the exact row is a category, so the name is refused.
  def test_a_category_entry_is_refused_even_among_factor_rows_it_prefixes
    replay(type: "type_category")

    assert_refused_before_write(**kwargs(health_factors: [ factor(name: "4PS") ]))
  end

  def test_a_name_no_entry_has_is_refused
    replay(type: "type_not_on_file")

    assert_refused_before_write(**kwargs(health_factors: [ factor(name: "SYN FACTOR NOT ON FILE") ]))
  end

  # The visit pre-read names DFN 990037; a save for another patient is refused
  # inside the lock, and the lock is released.
  def test_a_visit_of_another_patient_is_refused_inside_the_lock
    replay

    assert_refused_before_write(**kwargs(patient: OTHER_PATIENT))
    assert_operator rpcs.index(DDR_LOCK), :<, rpcs.index(DDR_GETS)
    assert_equal 1, unlock_calls.length
  end

  # AMHG answers 0~Add Health Factor when it does not file the factor (the
  # build's reply for a name the type file does not hold).
  def test_amhg_error_reply_is_an_outcome_unknown_save_error_and_unlocks
    replay(save: "save_name_not_on_file")

    err = assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs) }

    refute_empty amhg_calls
    assert_match(/outcome (is )?unknown/i, err.message)
    assert_match(/may have been filed/i, err.message)
    refute_includes err.message, "Add Health Factor"
    assert_equal 1, unlock_calls.length
  end

  # The read-back holds the comment the build filed (SYN HF); a save that sent
  # another comment is not confirmed by it.
  def test_a_readback_that_does_not_match_what_was_sent_is_not_confirmed
    replay

    err = assert_raises(BH::SaveError) { BH.save_health_factors(**kwargs(health_factors: [ factor(comment: "OTHER") ])) }

    assert_match(/may have been|outcome unknown|not confirmed/i, err.message)
    refute_includes err.message, PATIENT
    assert_equal 1, unlock_calls.length
  end

  # M LOCK + is incremental per $J, so the broker grants a second save on the
  # same job the same ^AMHREC(ien). The in-process guard is the exclusion.
  class ReenterOnWrite < SimpleDelegator
    attr_reader :inner_error, :calls_before, :calls_after

    def initialize(client, &inner)
      super(client)
      @inner = inner
    end

    def call_rpc_global_array(rpc_name, *params)
      if rpc_name == RPC && !@reentered
        @reentered = true
        @calls_before = calls.length
        begin
          @inner.call
        rescue StandardError => e
          @inner_error = e
        end
        @calls_after = calls.length
      end
      super
    end
  end

  def test_a_reentrant_save_on_the_same_client_and_record_is_refused_before_any_rpc
    replay
    wrapper = ReenterOnWrite.new(@client) { BH.save_health_factors(**kwargs) }
    RpmsRpc.configure { |cfg| cfg.client = wrapper }

    assert_equal RECORD_IEN, BH.save_health_factors(**kwargs)

    assert_instance_of BH::SaveError, wrapper.inner_error
    assert_match(/in progress/i, wrapper.inner_error.message)
    assert_equal wrapper.calls_before, wrapper.calls_after, "a refused nested save sends no RPC"
    assert_equal 1, amhg_calls.length
    assert_equal 1, lock_calls.length
  end

  # --- argument guards: refused before AMHG -----------------------------------

  def test_blank_or_whitespace_name_is_refused_before_any_rpc
    [ "", "  ", "\t" ].each do |blank|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(name: blank) ]))
      assert_empty rpcs.grep(String), "name #{blank.inspect} must be refused before any RPC"
    end
  end

  def test_level_outside_the_dd_set_is_refused
    %w[YES minimal M].each do |bad|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(level: bad) ]))
    end
  end

  def test_invalid_quantity_is_refused
    %w[abc -1 100000 1.555 01 +1 1e2].each do |bad|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(quantity: bad) ]))
    end
  end

  def test_comment_over_245_bytes_is_refused
    [ "X" * 246, "é" * 123 ].each do |long|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(comment: long) ]))
    end
  end

  def test_name_over_40_bytes_is_refused_without_a_type_pre_read
    [ "N" * 41, "é" * 21 ].each do |long|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(name: long) ]))
      refute(@client.calls.any? { |c| c[:rpc] == DDR_LISTER && c[:params].first["PART"] == long })
    end
  end

  def test_separators_and_control_characters_are_refused
    [ "|", "~", "*", "^", "\x1e", "\n" ].each do |bad|
      replay
      assert_refused_before_write(/separator|control/i, **kwargs(health_factors: [ factor(comment: "SYN#{bad}") ]))
    end
    replay
    assert_refused_before_write(/separator|control/i, **kwargs(health_factors: [ factor(name: "BAD|NAME") ]))
    replay
    assert_refused_before_write(/separator|control/i, **kwargs(health_factors: [ factor(level: "A|B") ]))
  end

  def test_at_sign_in_comment_level_or_quantity_is_refused
    %i[comment level quantity].each do |field|
      replay
      assert_refused_before_write(**kwargs(health_factors: [ factor(field => "@") ]))
    end
  end

  def test_more_than_25_health_factors_are_refused_without_a_type_pre_read
    factors = (1..26).map { |n| factor(name: format("SYN HF LIMIT %02d", n)) }
    replay

    assert_refused_before_write(**kwargs(health_factors: factors))
    refute(@client.calls.any? { |c| c[:rpc] == DDR_LISTER && c[:params].first["FILE"] == HF_TYPE_FILE })
  end

  def test_empty_list_duplicate_name_and_blank_record_ien_are_refused
    [
      kwargs(health_factors: []),
      kwargs(mode: :add, health_factors: []),
      kwargs(health_factors: [ factor, factor(comment: "OTHER") ]),
      kwargs(record_ien: ""),
      kwargs(record_ien: "   ")
    ].each do |args|
      replay
      assert_refused_before_write(**args)
    end
  end

  # --- registry ---------------------------------------------------------------

  def test_retry_safety_classifies_save_health_factors_as_non_idempotent_write
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(BH, :save_health_factors)
  end

  def test_required_rpcs_lists_amhg_save_health_factors_under_behavioral_health
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    assert_includes doc.fetch("modules").fetch("RpmsRpc::BehavioralHealth"), RPC
  end

  # No live run exists, so the row says pending and names no build.
  def test_rpcs_md_documents_save_health_factors_as_pending_until_a_live_run
    text = File.read(RPCS_MD_PATH, encoding: Encoding::UTF_8)
    bh_section = text[/## Behavioral Health writes.*?^(?=## |\z)/m]
    refute_nil bh_section, "Behavioral Health section missing from docs/rpcs.md"
    refute_includes bh_section, "bcer-9.0-20261012-e7923a4-ydb"
    row = bh_section.lines.find { |line| line.include?("`AMHG SAVE HEALTH FACTORS`") }
    refute_nil row
    assert_match(/\|\s*pending-capture\s*\|\s*\z/, row.strip)
    refute_match(/passed on/, bh_section)
    assert_includes text, "HF^AMHGSVF"
    assert_includes text, "AMHGRPC"
  end

  def test_mappings_ihs_defines_amhg_save_health_factors
    assert_includes File.read(MAPPINGS_PATH), "DataMapper.define(:amhg_save_health_factors)",
                    "production mapping :amhg_save_health_factors must ship with save_health_factors"
  end
end
