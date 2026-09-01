# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/progress_note"

class ProgressNoteTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090060"
  TITLE_IEN = "3001"
  NOTE_IEN  = "5001"
  USER_DUZ  = "301"

  # Broker stub that returns one canned raw response for every RPC —
  # for exercising nil/garbage response paths MockClient can't produce.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  def test_create_returns_new_note_ien_on_success
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_create_record, DFN, "5001")
    end

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert result[:success]
    assert_equal 5001, result[:ien]
  end

  def test_create_dispatches_tiu_create_record_with_dfn_visit_title
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_create_record, DFN, "5001")
    end

    RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU CREATE RECORD" }
    assert_equal [ DFN, VISIT_IEN, TITLE_IEN ], call[:params]
  end

  def test_create_returns_failure_on_zero_response
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_create_record, DFN, "0")
    end
    refute RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)[:success]
  end

  def test_list_returns_documents_for_dfn_in_default_all_context
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:tiu_documents_by_context, DFN, [
        { ien: 5001, title: "Progress Note", status: "UNSIGNED", author_duz: "301" },
        { ien: 5002, title: "Discharge Summary", status: "SIGNED", author_duz: "305" }
      ])
    end

    docs = RpmsRpc::ProgressNote.list(DFN)
    assert_equal 2, docs.length
  end

  def test_list_passes_each_context_code_to_rpc
    expected = { all: "1", by_author: "2", by_visit: "3", unsigned: "4" }
    expected.each do |ctx, code|
      RpmsRpc.mock! do |m|
        m.seed_keyed_collection(:tiu_documents_by_context, DFN, [])
      end
      RpmsRpc::ProgressNote.list(DFN, context: ctx)
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU DOCUMENTS BY CONTEXT" }
      assert_equal code, call[:params][1], "context #{ctx} should map to #{code}"
    end
  end

  def test_list_raises_on_unknown_context
    assert_raises(ArgumentError) { RpmsRpc::ProgressNote.list(DFN, context: :nope) }
  end

  def test_fetch_text_returns_note_body
    RpmsRpc.mock! do |m|
      m.seed_text(:tiu_get_record_text, NOTE_IEN, "S: chief complaint\nO: findings\n")
    end

    assert_match(/chief complaint/, RpmsRpc::ProgressNote.fetch_text(NOTE_IEN))
  end

  def test_authorize_lock_unlock_return_booleans
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_authorization, NOTE_IEN, true)
      m.seed_scalar(:tiu_lock_record, NOTE_IEN, true)
      m.seed_scalar(:tiu_unlock_record, NOTE_IEN, true)
    end

    assert RpmsRpc::ProgressNote.authorize(NOTE_IEN, USER_DUZ)
    assert RpmsRpc::ProgressNote.lock(NOTE_IEN, USER_DUZ)
    assert RpmsRpc::ProgressNote.unlock(NOTE_IEN, USER_DUZ)
  end

  def test_update_text_returns_success_result
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "0")
    end

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "new text body")
    assert result[:success]
  end

  def test_update_text_dispatches_with_note_ien_and_text
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "0")
    end
    RpmsRpc::ProgressNote.update_text(NOTE_IEN, "BODY")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SET DOCUMENT TEXT" }
    assert_equal [ NOTE_IEN, "BODY" ], call[:params]
  end

  def test_create_result_has_exact_gateway_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_create_record, DFN, "5001")
    end

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal %i[success ien raw], result.keys
    assert_equal "5001", result[:raw]
  end

  def test_create_error_string_response_returns_failure_with_raw
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_create_record, DFN, "-1^Invalid title")
    end

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1^Invalid title", result[:raw]
  end

  def test_create_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::ProgressNote.create(DFN, VISIT_IEN, TITLE_IEN)
    assert_equal({ success: false, ien: nil, raw: nil }, result)
  end

  def test_list_scalar_error_response_returns_empty_array
    # A broker returning a bare error string where a list is expected
    # must not crash (previously raised NoMethodError on String#filter_map)
    # and must yield NO rows — never a bogus "document" parsed out of the
    # error text (e.g. ien: -1, title: "NO DOCUMENTS FOUND").
    stub_broker_response("-1^NO DOCUMENTS FOUND")

    assert_equal [], RpmsRpc::ProgressNote.list(DFN)
  end

  def test_list_nil_broker_response_returns_empty_array
    stub_broker_response(nil)

    assert_equal [], RpmsRpc::ProgressNote.list(DFN)
  end

  def test_fetch_text_nil_broker_response_returns_nil
    stub_broker_response(nil)

    assert_nil RpmsRpc::ProgressNote.fetch_text(NOTE_IEN)
  end

  def test_authorize_lock_unlock_garbage_response_returns_false
    stub_broker_response("-1^SOMETHING WENT WRONG")

    refute RpmsRpc::ProgressNote.authorize(NOTE_IEN, USER_DUZ)
    refute RpmsRpc::ProgressNote.lock(NOTE_IEN, USER_DUZ)
    refute RpmsRpc::ProgressNote.unlock(NOTE_IEN, USER_DUZ)
  end

  def test_update_text_result_has_exact_two_key_shape
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "0")
    end

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "new text body")
    assert_equal %i[success raw], result.keys
  end

  def test_update_text_nil_broker_response_does_not_raise
    stub_broker_response(nil)

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "new text body")
    assert_equal({ success: false, raw: nil }, result)
  end

  def test_update_text_garbage_response_returns_failure_with_raw
    RpmsRpc.mock! do |m|
      m.seed_scalar(:tiu_set_document_text, NOTE_IEN, "-1^Document locked")
    end

    result = RpmsRpc::ProgressNote.update_text(NOTE_IEN, "new text body")
    refute result[:success]
    assert_equal "-1^Document locked", result[:raw]
  end

  def test_blank_args_return_safe_defaults
    refute RpmsRpc::ProgressNote.create(nil, VISIT_IEN, TITLE_IEN)[:success]
    assert_equal [], RpmsRpc::ProgressNote.list(nil)
    assert_nil RpmsRpc::ProgressNote.fetch_text("0")
    refute RpmsRpc::ProgressNote.authorize(nil, USER_DUZ)
    refute RpmsRpc::ProgressNote.lock(NOTE_IEN, nil)
    refute RpmsRpc::ProgressNote.update_text(nil, "x")[:success]
    refute RpmsRpc::ProgressNote.update_text(NOTE_IEN, nil)[:success]
  end
end
