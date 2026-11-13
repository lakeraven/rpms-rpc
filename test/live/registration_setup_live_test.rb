# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration_setup"
require "rpms_rpc/api/ddr_fileman"

# RegistrationSetup on a real build: the legal-document eligibility modifiers
# (#9000030) and the site's local patient record flags (#26.11, with their
# history in #26.12), the two registration tables BPRM edits under Table
# Maintenance (lakeraven-ehr#982, #983). Every write is read back through
# FileMan, with DDR GETS ENTRY DATA for the fields the module's own reads do
# not return.
class RegistrationSetupLiveTest < LiveSpec::Test
  writes!

  RS = RpmsRpc::RegistrationSetup

  def test_a_name_change_modifier_is_added_renamed_and_read_back
    name = "LIVE SPEC PROOF #{stamp}"
    added = RS.add_eligibility_modifier(name: name.downcase, type: "N")
    assert added[:success], added.inspect

    row = RS.eligibility_modifier_table.find { |entry| entry[:ien] == added[:ien] }
    assert_equal({ ien: added[:ien], name: name, type: "N", legal_document: true }, row, "filed upper case, as BPRM does")
    assert_equal [ name, "N" ], fileman(RS::MODIFIER_FILE, "#{added[:ien]},", ".01;.02")

    renamed = RS.rename_eligibility_modifier(added[:ien], name: "#{name} RENAMED")
    assert_equal({ success: true }, renamed)
    assert_equal [ "#{name} RENAMED", "N" ], fileman(RS::MODIFIER_FILE, "#{added[:ien]},", ".01;.02"), "the type is left as it was"
  end

  def test_an_eligibility_status_reason_is_listed_and_never_renamed
    table = RS.eligibility_modifier_table
    reason = table.find { |entry| entry[:type] == "C" }
    assert reason, "the build has an eligibility-status reason of type C: #{table.first(5).inspect}"
    refute reason[:legal_document]

    refused = RS.rename_eligibility_modifier(reason[:ien], name: "NOT CHANGED HERE")
    assert_equal :invalid, refused[:error], refused.inspect
    assert_equal [ reason[:name], "C" ], fileman(RS::MODIFIER_FILE, "#{reason[:ien]},", ".01;.02")
  end

  def test_a_type_outside_n_l_s_is_refused_with_nothing_filed
    before = RS.eligibility_modifier_table.size
    %w[A C NLA].each do |type|
      assert_equal :invalid, RS.add_eligibility_modifier(name: "LIVE SPEC REFUSED", type: type)[:error], type
    end
    assert_equal before, RS.eligibility_modifier_table.size
  end

  def test_a_clinical_flag_is_added_read_back_with_its_history_then_inactivated
    clinical = RS.flag_types.find { |type| type[:name] == "CLINICAL" }
    assert clinical, "the build has a CLINICAL PRF TYPE (#26.16): #{RS.flag_types.inspect}"
    name = "LIVE SPEC FLAG #{stamp}"

    added = RS.add_local_flag(name: name, type: clinical[:ien], review_days: 365, notification_days: 30,
                              description: [ "Shown to every user.", "Reviewed yearly." ])
    assert added[:success], added.inspect
    ien = added[:ien]

    flag = RS.local_flag(ien)
    assert_equal({ ien: ien, name: name, active: true, type_ien: clinical[:ien], type: "CLINICAL", review_days: 365,
                   notification_days: 30, description: [ "Shown to every user.", "Reviewed yearly." ] }, flag)
    assert_equal [ name, "1", clinical[:ien].to_s, "365", "30" ], fileman(RS::FLAG_FILE, "#{ien},", ".01;.02;.03;.04;.05")

    history = RS.local_flag_history(ien)
    assert_equal 1, history.size, history.inspect
    assert_equal [ RS::NEW_FLAG_REASON ], history.first[:reason]
    assert_equal client.duz.to_i, history.first[:edited_by]
    assert_in_delta Time.now.to_i, history.first[:edited_at].to_i, 600
    stored = fileman(RS::HISTORY_FILE, "#{history.first[:ien]},", ".02").first
    refute_match(/\.\d*0\z/, stored, "the edit time is stored with no trailing zero, as $$NOW^XLFDT gives it")

    changed = RS.update_local_flag(ien, name: name, type: clinical[:ien], review_days: 365, notification_days: 30,
                                   active: false, reason: [ "No longer used." ], description: [ "Shown to every user." ])
    assert_equal({ success: true }, changed)
    assert_equal [ "0" ], fileman(RS::FLAG_FILE, "#{ien},", ".02"), "inactivated, not deleted"
    assert_equal [ "Shown to every user." ], RS.local_flag(ien)[:description]
    assert_equal [ [ RS::NEW_FLAG_REASON ], [ "No longer used." ] ], RS.local_flag_history(ien).map { |entry| entry[:reason] }
  end

  def test_flag_refusals_file_nothing
    clinical = RS.flag_types.find { |type| type[:name] == "CLINICAL" }
    name = "LIVE SPEC REFUSED #{stamp}"
    refusals = [
      RS.add_local_flag(name: name, type: clinical[:ien], review_days: 30, notification_days: 31),
      RS.add_local_flag(name: name, type: clinical[:ien], review_days: 0, notification_days: 5),
      RS.add_local_flag(name: "9 STARTS WITH A DIGIT", type: clinical[:ien], review_days: 0, notification_days: 0),
      RS.add_local_flag(name: name, type: 999_999, review_days: 0, notification_days: 0)
    ]
    assert_equal [ :invalid ] * 4, refusals.map { |result| result[:error] }, refusals.inspect
    assert_nil RS.local_flags.find { |row| row[:name] == name }

    first = RS.add_local_flag(name: name, type: clinical[:ien], review_days: 0, notification_days: 0)
    assert first[:success], first.inspect
    assert_equal :invalid, RS.add_local_flag(name: name, type: clinical[:ien], review_days: 0, notification_days: 0)[:error],
                 "a name already a flag"
    assert_equal :invalid, RS.update_local_flag(first[:ien], name: name, type: clinical[:ien], review_days: 0,
                                                notification_days: 0, active: true, reason: [])[:error], "an edit needs a reason"
  end

  private

  def stamp = Time.now.strftime("%H%M%S")

  def fileman(file, iens, fields)
    reply = client.with_context(RS::CONTEXT) { RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: fields, flags: "I") }
    refute_nil reply, "DDR GETS gave no reply for ##{file} #{iens}"
    fields.split(";").map { |field| reply[:fields].dig(field, :internal).to_s }
  end
end
