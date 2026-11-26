# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/terminology"

# RpmsRpc::Terminology's writes on a real build (rpms-rpc#963): the
# signed-on user's SNOMED CT search preferences, saved and read back, and
# the pick VueCentric reports after a selection. Each test leaves the user's
# preferences as it found them. The front desk clerk's row lacks BSTSRPC,
# and every call raises rather than reading as none saved. It WRITES against
# a disposable local container only.
class TerminologyPreferencesLiveTest < LiveSpec::Test
  runs_as :provider, :front_desk_clerk
  writes!

  WANTED = { search_type: :synonym, max: 100, parents_children: true, autocomplete_disabled: true }.freeze

  def test_saved_preferences_read_back_and_are_restored
    return clerk_refused_preferences if role == :front_desk_clerk

    before = RpmsRpc::Terminology.preferences
    wanted = before == WANTED ? WANTED.merge(max: 200) : WANTED
    begin
      assert RpmsRpc::Terminology.update_preferences(**wanted)
      assert_equal wanted, RpmsRpc::Terminology.preferences, "the saved row reads back"

      error = assert_raises(RpmsRpc::Terminology::BstsError) { RpmsRpc::Terminology.update_preferences(max: 75) }
      assert_equal "Invalid Record Count Value", error.package_message
      assert_equal wanted, RpmsRpc::Terminology.preferences, "a refused save files nothing"
    ensure
      before ? RpmsRpc::Terminology.update_preferences(**before) : RpmsRpc::Terminology.delete_preferences
    end
    assert_equal before, RpmsRpc::Terminology.preferences, "the user's preferences are restored"
  end

  # BSTS answers success. These builds carry BSTS*2.0*7, which switched
  # concept-selection logging off, so nothing is queued and there is no row
  # to read back or remove.
  def test_record_selection_reports_a_pick
    return refused_without_bstsrpc { RpmsRpc::Terminology.record_selection("73211009") } if role == :front_desk_clerk

    concept = RpmsRpc::Terminology.search("diabetes mellitus").first
    refute_nil concept
    assert RpmsRpc::Terminology.record_selection(concept[:concept_id], description_id: concept[:description_id],
                                                                   subset: "SRCH Diabetes")
  end

  private

  def clerk_refused_preferences
    refused_without_bstsrpc { RpmsRpc::Terminology.preferences }
    refused_without_bstsrpc { RpmsRpc::Terminology.update_preferences(**WANTED) }
    refused_without_bstsrpc { RpmsRpc::Terminology.delete_preferences }
  end

  def refused_without_bstsrpc(&)
    assert_raises(RpmsRpc::Client::RpcRefusedError, &)
  end
end
