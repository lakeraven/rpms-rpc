# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health/groups"
require_relative "../../captured_replies"

# RpmsRpc::BehavioralHealth::Groups on the AMHG replies a fresh rpms-ydb
# container sent (test/fixtures/captured_replies/amhg-groups-cases.yml),
# replayed through CiaClient's GLOBAL ARRAY read, per ADR 0009: the parameter
# each read sends, and the empty and not-on-file answers. A fresh container
# has no BH group, so a filled row is not pinned here (rpms-rpc#622). These
# replies are why Wire#rows and #text_lines split the frame (#673).
class BehavioralHealthGroupsTest < Minitest::Test
  G = RpmsRpc::BehavioralHealth::Groups
  SLUG = "amhg-groups-cases"
  NOT_ON_FILE = "999999"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new((capture(name)["rpc"] || "AMHG GET GROUPS") => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| c[:params] }

  def test_groups_with_none_on_file_is_empty_and_sends_from_to_provider
    client = replay("groups_none")

    assert_empty G.groups("4", from: "3000101", to: "3271231"), "the typed header is not a group"
    assert_equal [ capture("groups_none")["inputs"] ], sent(client)
  end

  # GRPINFO answers one row for any IEN; for one not on file it is blank but
  # for the IEN and the encounter-date column's empty $$VCDT text.
  def test_group_information_for_an_ien_not_on_file_is_a_row_of_blanks
    replay("group_information_not_on_file")

    info = G.group_information(NOT_ON_FILE)
    assert_equal NOT_ON_FILE, info[:ien]
    assert_equal "1700,,,12,0", info[:encounter_date], "what the build sends for an empty encounter date"
    assert_empty info.except(:ien, :encounter_date).values.compact
  end

  %w[group_patients group_cpt group_edu group_pov group_secondary_providers].each do |reader|
    define_method("test_#{reader}_for_a_group_not_on_file_is_empty") do
      client = replay("#{reader}_not_on_file")

      assert_empty G.public_send(reader, NOT_ON_FILE), "#{reader}: the typed header is not a row"
      assert_equal [ [ NOT_ON_FILE ] ], sent(client), "#{reader} sends the group IEN alone"
    end
  end

  def test_group_soap_for_a_group_not_on_file_has_no_lines
    replay("group_soap_not_on_file")

    assert_empty G.group_soap(NOT_ON_FILE), "the SOAP header (with the sequence echo) is not a line of text"
  end
end
