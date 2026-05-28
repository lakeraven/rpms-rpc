# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/note_template"

class NoteTemplateTest < Minitest::Test
  USER_DUZ    = "301"
  TEMPLATE    = "4001"
  DFN         = "8791"
  VISIT_IEN   = "2090060"

  def teardown
    RpmsRpc.reset!
  end

  def test_roots_returns_root_templates_for_user
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:template_roots, USER_DUZ, [
        { ien: 1, name: "Personal", type: "FOLDER" },
        { ien: 2, name: "Shared",   type: "FOLDER" }
      ])
    end

    roots = RpmsRpc::NoteTemplate.roots(USER_DUZ)
    assert_equal 2, roots.length
    assert_equal "Personal", roots.first[:name]
  end

  def test_items_returns_children_of_a_template
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:template_items, TEMPLATE, [
        { ien: 11, name: "Subjective", type: "TEMPLATE", parent_ien: 4001 },
        { ien: 12, name: "Objective",  type: "TEMPLATE", parent_ien: 4001 }
      ])
    end

    items = RpmsRpc::NoteTemplate.items(TEMPLATE)
    assert_equal [ 11, 12 ], items.map { |i| i[:ien] }
  end

  # The gateway is a passthrough — token substitution happens in the
  # underlying TIU TEMPLATE GETBOIL RPC (server-side). The mock returns
  # what a real server would: already-substituted text. The test asserts
  # the gateway returns it verbatim and does NOT see raw |TOKEN| markers.
  def test_boilerplate_returns_server_substituted_text_verbatim
    substituted = "Patient: DOE,JOHN\nVisit: 2026-05-27 10:30\nChief Complaint:"

    RpmsRpc.mock! do |m|
      m.seed_text(:template_boilerplate, TEMPLATE, substituted)
    end

    body = RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, dfn: DFN, visit_ien: VISIT_IEN)
    assert_equal substituted, body
    refute_match(/\|[A-Z]+\|/, body, "gateway should not see raw |TOKEN| markers")
  end

  def test_boilerplate_dispatches_with_template_dfn_visit_params
    RpmsRpc.mock! do |m|
      m.seed_text(:template_boilerplate, TEMPLATE, "x")
    end

    RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, dfn: DFN, visit_ien: VISIT_IEN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU TEMPLATE GETBOIL" }
    assert_equal [ TEMPLATE, DFN, VISIT_IEN ], call[:params]
  end

  def test_text_returns_unsubstituted_template_body
    RpmsRpc.mock! do |m|
      m.seed_text(:template_text, TEMPLATE, "Raw |NAME|")
    end

    assert_equal "Raw |NAME|", RpmsRpc::NoteTemplate.text(TEMPLATE)
  end

  def test_access_level_returns_string
    RpmsRpc.mock! do |m|
      m.seed_scalar(:template_access_level, TEMPLATE, "READ_WRITE")
    end

    assert_equal "READ_WRITE", RpmsRpc::NoteTemplate.access_level(TEMPLATE, USER_DUZ)
  end

  def test_blank_args_return_empty_or_nil
    assert_equal [], RpmsRpc::NoteTemplate.roots(nil)
    assert_equal [], RpmsRpc::NoteTemplate.items("0")
    assert_nil RpmsRpc::NoteTemplate.boilerplate(nil, dfn: DFN, visit_ien: VISIT_IEN)
    assert_nil RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, dfn: nil, visit_ien: VISIT_IEN)
    assert_nil RpmsRpc::NoteTemplate.text("")
    assert_nil RpmsRpc::NoteTemplate.access_level(TEMPLATE, nil)
  end

  def test_dfn_and_visit_ien_are_required_keywords
    assert_raises(ArgumentError) { RpmsRpc::NoteTemplate.boilerplate(TEMPLATE) }
    assert_raises(ArgumentError) { RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, dfn: DFN) }
    assert_raises(ArgumentError) { RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, visit_ien: VISIT_IEN) }
  end
end
