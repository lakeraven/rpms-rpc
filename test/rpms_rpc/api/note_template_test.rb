# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/note_template"
require_relative "../captured_replies"

# The TIU template reads (TIUSRVT). The replies are
# test/fixtures/captured_replies/note-template.yml, captured live as the
# clinician PROVIDER,TEST on the build's shared templates and the seed
# patient DFN 4, and replayed through CiaClient's own reply grammar
# (rpms-rpc#620).
class NoteTemplateTest < Minitest::Test
  SLUG = "note-template"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # GETROOTS(TIUY,USER) (TIUSRVT.m:30) takes the user alone; each row is
  # IEN^TYPE^STATUS^NAME^EXCLUDE^BLANK LINES^PERSONAL OWNER^HAS CHILDREN^...
  # (NODEDATA, TIUSRVT.m:104-109). The old mapping read TYPE as the name and
  # STATUS as the type (#219).
  def test_roots_send_the_user_and_parse_by_the_nodedata_layout
    client = replay("roots")

    roots = RpmsRpc::NoteTemplate.roots(200)

    assert_equal [ [ "TIU TEMPLATE GETROOTS", [ "200" ] ] ], sent(client)
    assert_equal [ 1, 1952, 53 ], roots.map { |r| r[:ien] }
    assert_equal({ ien: 1, type: "R", status: "A", name: "Shared Templates", exclude_from_group_boilerplate: nil,
                   blank_lines: nil, personal_owner_duz: nil, has_children: 1 }, roots.first)
    assert_equal [ "R", "TF", "CF" ], roots.map { |r| r[:type] }
  end

  # GETITEMS(TIUY,TIUDA) (TIUSRVT.m:42) lists TIUDA's children, each row by
  # NODEDATA of the child (TIUSRVT.m:51). Nothing in the row names a parent:
  # the old :parent_ien read the NAME piece as an integer.
  def test_items_parse_by_the_nodedata_layout_with_no_parent_piece
    client = replay("items")

    items = RpmsRpc::NoteTemplate.items(1)

    assert_equal [ [ "TIU TEMPLATE GETITEMS", [ "1" ] ] ], sent(client)
    assert_equal [ 3454, 3318, 3419, 4, 3194 ], items.map { |i| i[:ien] }
    assert_equal [ "SCREENING BUNDLE", "New Patient Visit Note" ], items.first(2).map { |i| i[:name] }
    assert_equal [ "T", "G", "G", "C", "C" ], items.map { |i| i[:type] }
    assert_equal [ 0, 3, 3, 1, 1 ], items.map { |i| i[:has_children] }
    assert_equal [ nil, 1 ], items.first(2).map { |i| i[:blank_lines] }
    refute items.first.key?(:parent_ien)
  end

  # GETBOIL(TIUY,TIUDA) (TIUSRVT.m:55) takes the template alone and returns
  # its UNEXPANDED boilerplate (TIUSRVT.m:62-64); expansion is GETTEXT.
  # Three actuals died in M (ACTLSTTOOLONG) (#219).
  def test_boilerplate_sends_only_the_template_and_returns_the_unexpanded_text
    client = replay("boilerplate")

    text = RpmsRpc::NoteTemplate.boilerplate(3337)

    assert_equal [ [ "TIU TEMPLATE GETBOIL", [ "3337" ] ] ], sent(client)
    assert_equal "VITALS:\n  |VITALS FOR VISIT CONTEXT|\n{FLD:BLANK LINE1}", text
  end

  # GETTEXT(TIUY,DFN,VSTR,TIUX) (TIUSRVT.m:67) expands the TEXT it is handed,
  # each line a TIUX(n,0) node (BLRPLT^TIUSRVD, TIUSRVD.m:82-83). The reply
  # starts with the word-processing 0-node header, which text drops.
  def test_text_sends_each_line_as_a_tiux_node_and_drops_the_header
    client = replay("text")

    text = RpmsRpc::NoteTemplate.text([ "Name: |PATIENT NAME|", "Sex: |PATIENT SEX|" ], dfn: "4")

    assert_equal "Name: DEMO,PATIENT ONE\nSex: FEMALE", text
    assert_equal CapturedReplies.flow_calls(SLUG, "text").map(&:first), sent(client).map(&:first)
    assert_equal [ "4", "", { [ 1, 0 ] => "Name: |PATIENT NAME|", [ 2, 0 ] => "Sex: |PATIENT SEX|" } ],
                 sent(client).first.last
  end

  def test_access_level_returns_the_routines_code
    client = replay("access_level")

    assert_equal "2", RpmsRpc::NoteTemplate.access_level(1, 200)
    assert_equal [ [ "TIU TEMPLATE ACCESS LEVEL", [ "1", "200" ] ] ], sent(client)
  end

  def test_blank_args_reach_no_wire
    client = replay("roots")

    assert_equal [], RpmsRpc::NoteTemplate.roots(nil)
    assert_equal [], RpmsRpc::NoteTemplate.items("0")
    assert_nil RpmsRpc::NoteTemplate.boilerplate(nil)
    assert_nil RpmsRpc::NoteTemplate.text([], dfn: "4")
    assert_nil RpmsRpc::NoteTemplate.text([ "x" ], dfn: "")
    assert_nil RpmsRpc::NoteTemplate.access_level(1, nil)
    assert_empty sent(client)
  end

  def test_boilerplate_no_longer_takes_a_patient_or_visit
    assert_raises(ArgumentError) { RpmsRpc::NoteTemplate.boilerplate(3337, dfn: "4", visit_ien: "1") }
  end
end
