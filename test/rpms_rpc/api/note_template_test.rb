# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
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

  # GETROOTS and GETITEMS rows are IEN^TYPE^STATUS^NAME^EXCLUDE^BLANK
  # LINES^PERSONAL OWNER^HAS CHILDREN^... (TIUSRVT.m:4-29, built by
  # NODEDATA, TIUSRVT.m:104-109). The old mapping read TYPE as the name and
  # STATUS as the type (#219).
  ROOT_ROW = "1^P^A^My Templates^0^0^301^1"
  ITEM_ROWS = [ "11^T^A^Subjective^0^1^^0", "12^G^A^Objective^0^0^^1" ].freeze

  def test_roots_parse_by_the_nodedata_layout
    RpmsRpc.mock! { |m| m.seed_raw_lines(:template_roots, USER_DUZ, [ ROOT_ROW ]) }

    root = RpmsRpc::NoteTemplate.roots(USER_DUZ).first
    assert_equal({ ien: 1, type: "P", status: "A", name: "My Templates",
                   exclude_from_group_boilerplate: "0", blank_lines: 0,
                   personal_owner_duz: "301", has_children: 1 }, root)
  end

  # GETROOTS(TIUY,USER) (TIUSRVT.m:30): one actual, the user.
  def test_roots_send_the_user
    RpmsRpc.mock!
    RpmsRpc::NoteTemplate.roots(USER_DUZ)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU TEMPLATE GETROOTS" }
    assert_equal [ USER_DUZ ], call[:params]
  end

  # GETITEMS(TIUY,TIUDA) (TIUSRVT.m:42) lists the children of TIUDA, each
  # row by NODEDATA of the child (TIUSRVT.m:51). Nothing in the row names a
  # parent: the old :parent_ien read the NAME piece as an integer.
  def test_items_parse_by_the_nodedata_layout_with_no_parent_piece
    RpmsRpc.mock! { |m| m.seed_raw_lines(:template_items, TEMPLATE, ITEM_ROWS) }

    items = RpmsRpc::NoteTemplate.items(TEMPLATE)
    assert_equal [ 11, 12 ], items.map { |i| i[:ien] }
    assert_equal [ "Subjective", "Objective" ], items.map { |i| i[:name] }
    assert_equal [ "T", "G" ], items.map { |i| i[:type] }
    assert_equal [ 0, 1 ], items.map { |i| i[:has_children] }
    refute items.first.key?(:parent_ien)
  end

  # GETBOIL(TIUY,TIUDA) (TIUSRVT.m:55) takes the template alone and returns
  # its UNEXPANDED boilerplate (TIUSRVT.m:55, 62-64); expansion is GETTEXT.
  # Three actuals died in M (ACTLSTTOOLONG) (#219).
  def test_boilerplate_returns_the_unexpanded_text
    RpmsRpc.mock! { |m| m.seed_text(:template_boilerplate, TEMPLATE, "Patient: |PATIENT NAME|\nChief Complaint:") }

    assert_equal "Patient: |PATIENT NAME|\nChief Complaint:", RpmsRpc::NoteTemplate.boilerplate(TEMPLATE)
  end

  def test_boilerplate_sends_only_the_template_ien
    RpmsRpc.mock! { |m| m.seed_text(:template_boilerplate, TEMPLATE, "x") }

    RpmsRpc::NoteTemplate.boilerplate(TEMPLATE)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU TEMPLATE GETBOIL" }
    assert_equal [ TEMPLATE ], call[:params]
  end

  # GETTEXT(TIUY,DFN,VSTR,TIUX) (TIUSRVT.m:67) expands the TEXT it is
  # handed — there is no template IEN on this wire. The mock keys the
  # reply by its first formal, the DFN (#259).
  def test_text_returns_the_expanded_text
    RpmsRpc.mock! do |m|
      m.seed_text(:template_text, DFN, "^^1^1^3260527^^\nPatient: DOE,JOHN")
    end

    assert_equal "^^1^1^3260527^^\nPatient: DOE,JOHN",
                 RpmsRpc::NoteTemplate.text([ "Patient: |PATIENT NAME|" ], dfn: DFN, visit_string: VISIT_IEN)
  end

  def test_text_sends_each_line_as_a_tiux_n_0_node
    RpmsRpc.mock! { |m| m.seed_text(:template_text, DFN, "x") }

    RpmsRpc::NoteTemplate.text([ "one", "two" ], dfn: DFN, visit_string: "349;3260527.1;A;7")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU TEMPLATE GETTEXT" }
    # BLRPLT^TIUSRVD reads @ROOT@(n,0) with ROOT="TIUX" (TIUSRVD.m:82-83).
    assert_equal [ DFN, "349;3260527.1;A;7", { [ 1, 0 ] => "one", [ 2, 0 ] => "two" } ], call[:params]
  end

  def test_text_returns_nil_for_no_lines_or_no_patient
    RpmsRpc.mock!
    assert_nil RpmsRpc::NoteTemplate.text([], dfn: DFN)
    assert_nil RpmsRpc::NoteTemplate.text([ "x" ], dfn: nil)
    assert_empty RpmsRpc.client.received_calls
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
    assert_nil RpmsRpc::NoteTemplate.boilerplate(nil)
    assert_nil RpmsRpc::NoteTemplate.text([ "x" ], dfn: "")
    assert_nil RpmsRpc::NoteTemplate.access_level(TEMPLATE, nil)
  end

  def test_boilerplate_no_longer_takes_a_patient_or_visit
    assert_raises(ArgumentError) { RpmsRpc::NoteTemplate.boilerplate(TEMPLATE, dfn: DFN, visit_ien: VISIT_IEN) }
  end
end
