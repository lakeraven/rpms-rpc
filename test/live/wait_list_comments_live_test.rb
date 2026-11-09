# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/wait_list"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# A wait-list entry's COMMENTS (field 1 of #9009017.11, the word-processing
# subfile #9009017.111), filed with DDR FILER and read with DDR GETS
# (rpms-rpc#641, rpms-ux S-SCH-10.1, 10.4, 10.7). Each filing is read back
# with FileMan (GETS^DIQ through DDR GETS ENTRY DATA): DDR LISTER cannot list
# a word-processing subfile.
class WaitListCommentsLiveTest < LiveSpec::Test
  writes!

  WL = RpmsRpc::WaitList
  PATIENT = 990_002
  CLINIC = "DEMO IHS CLINIC"

  def setup
    super
    clinic = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }.fetch(:hospital_location_id)
    found = WL.lists.find { |row| row[:clinic_ien] == clinic }
    @list = found ? found[:ien] : make_list(clinic)
    scoped { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "9009017.1", field: ".02", iens: "#{@list},", value: "0" } ]) }
    added = WL.add(list: @list, patient_dfn: PATIENT, added_on: Date.today, reason: WL.reasons("A").first[:ien],
                   recall_on: Date.today + 30)
    assert added[:success], added.inspect
    @entry = added[:ien]
  end

  def test_comments_file_then_replace_and_read_back_line_for_line
    assert_equal [], WL.comments(list: @list, entry: @entry), "a new entry has no comments"

    first = [ "First line of the note.", "Second: 2 of 2 ^ with a caret." ]
    result = WL.set_comments(list: @list, entry: @entry, lines: first)
    assert_equal({ success: true }, result)
    assert_equal first, WL.comments(list: @list, entry: @entry)

    replaced = [ "One line now." ]
    assert_equal({ success: true }, WL.set_comments(list: @list, entry: @entry, lines: replaced))
    assert_equal replaced, WL.comments(list: @list, entry: @entry), "a filing replaces the whole field"
  end

  def test_an_entry_not_on_file_is_refused_with_nothing_filed
    result = WL.set_comments(list: @list, entry: 999_999, lines: [ "x" ])
    assert_equal :not_found, result[:error], result.inspect
  end

  private

  def scoped(&) = RpmsRpc::ContextScope.scoped(RpmsRpc.client, WL::CONTEXT, &)

  def make_list(clinic)
    filed = scoped { RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [ { file: "9009017.1", field: ".01", iens: "+1,", value: clinic.to_s } ]) }
    assert filed[:success], filed.inspect
    filed[:iens][1].to_i
  end
end
