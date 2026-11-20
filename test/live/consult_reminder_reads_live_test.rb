# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/consult"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/reminders"

# Consult.for_patient (ORQQCN LIST), Consult.find (ORQQCN GET CONSULT),
# Consult.resubmittable (ORQQCN CANEDIT), and Reminders.unevaluated,
# .categories, .education_topics and .web_references (ORQQPXRM REMINDERS
# UNEVALUATED, REMINDER CATEGORIES, EDUCATION SUMMARY, REMINDER WEB). Each
# answer is checked against the file it reads with DDR: REQUEST/CONSULTATION
# (#123), REMINDER DEFINITION (#811.9) and its FINDINGS and WEB SITES
# multiples, REMINDER CATEGORY (#811.7) and EDUCATION TOPICS (#9999999.09).
# Read only.
#
# The pinned demo build files no consult and no reminder category, so on it
# the consult reads and categories prove the empty answer, checked against
# the empty file; a build that files them is checked entry by entry.
class ConsultReminderReadsLiveTest < LiveSpec::Test
  runs_as "PROV123"
  DFN = 2 # the demo patient
  REMINDER_WITH_OWN_SITES = 9 # IHS-INFLUENZA IMMUNIZATION: its own WEB SITES entry on the pinned build

  def test_consults_read_back_against_request_consultation
    consults = listed("123", ".02")
    if consults.empty?
      assert_empty RpmsRpc::Consult.for_patient(DFN), "#123 is empty, so ORQQCN LIST answers no consult"
      assert_empty RpmsRpc::Consult.for_patient(DFN, start_date: "3000101", end_date: "3991231")
      assert_nil RpmsRpc::Consult.find(1), "ORQQCN GET CONSULT answers -1^Invalid consult for an IEN not on file"
      assert_equal({ resubmittable: false, reason: "Invalid Consult Number" }, RpmsRpc::Consult.resubmittable(1))
      return
    end

    consults.first(3).each do |row|
      ien = row[:ien].to_i
      dfn = row[:pieces].first.to_i
      assert_includes RpmsRpc::Consult.for_patient(dfn).map { |c| c[:ien] }, ien, "#123 #{ien} is listed for its patient"
      found = RpmsRpc::Consult.find(ien)
      assert_equal dfn, found[:patient_dfn], "Consult.find reads #123 #{ien} .02"
      assert_includes [ true, false ], RpmsRpc::Consult.resubmittable(ien)[:resubmittable]
    end
  end

  def test_unevaluated_reminders_are_the_cover_sheet_list_the_engine_evaluates
    iens = RpmsRpc::Reminders.unevaluated(DFN)
    refute_empty iens, "ORQQPXRM REMINDERS UNEVALUATED answered no cover-sheet reminder: is this the pinned image?"
    iens.each do |ien|
      fields = entry("811.9", ien, ".01;1.6")
      refute_empty fields.dig(".01", :external).to_s, "#811.9 #{ien} is on file"
      refute_equal "1", fields.dig("1.6", :internal), "#811.9 #{ien} is not inactive (ADDREM^ORQQPX)"
    end
    assert_equal iens.sort, RpmsRpc::Reminders.applicable(DFN).map { |r| r[:id] }.sort,
                 "the engine evaluates exactly the unevaluated list (EVALCOVR^ORQQPX)"
  end

  def test_categories_read_back_against_reminder_category
    categories = RpmsRpc::Reminders.categories(DFN)
    if listed("811.7", ".01").empty?
      assert_empty categories, "#811.7 is empty, so no category can be listed"
      return
    end

    ids = categories.select { |c| c[:kind] == :category }.map { |c| c[:id] }
    categories.select { |c| c[:kind] == :reminder }.each do |row|
      assert_includes ids, row[:parent_id], "reminder row #{row.inspect} sits under a listed category"
      refute_empty entry("811.9", row[:reminder_ien], ".01").dig(".01", :external).to_s
    end
  end

  def test_education_topics_include_the_reminders_direct_education_findings
    RpmsRpc::Reminders.unevaluated(DFN).each do |ien|
      topics = RpmsRpc::Reminders.education_topics(ien)
      direct = listed("811.902", ".01", iens: ",#{ien},").filter_map do |finding|
        internal = finding[:pieces].first.to_s
        internal.split(";").first.to_i if internal.end_with?("AUTTEDT(")
      end
      assert_empty direct - topics.map { |t| t[:ien] }, "reminder #{ien}'s direct education findings are listed"
      topics.each do |topic|
        assert_equal entry("9999999.09", topic[:ien], ".01").dig(".01", :external), topic[:name]
      end
    end
  end

  def test_web_references_list_the_reminders_own_sites_then_the_general_ones
    own = listed("811.9002", ".01", iens: ",#{REMINDER_WITH_OWN_SITES},").map { |row| row[:pieces].first }
    refute_empty own, "#811.9 #{REMINDER_WITH_OWN_SITES} has no WEB SITES entry: is this the pinned image?"
    sites = RpmsRpc::Reminders.web_references(REMINDER_WITH_OWN_SITES)
    assert_equal own.sort, sites.first(own.size).map { |s| s[:url] }.sort, "the reminder's own sites come first"

    without_own = RpmsRpc::Reminders.unevaluated(DFN).find { |ien| listed("811.9002", ".01", iens: ",#{ien},").empty? }
    refute_nil without_own, "no cover-sheet reminder without its own web site to compare against"
    assert_equal RpmsRpc::Reminders.web_references(without_own), sites.drop(own.size),
                 "the rest are the site's general web sites, the same for every reminder"
  end

  private

  def listed(file, fields, iens: nil)
    got = RpmsRpc::DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP", max: "50")
    flunk "DDR LISTER on #{file} failed: #{got.inspect}" if got.nil? || got[:error]
    got[:entries]
  end

  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end
end
