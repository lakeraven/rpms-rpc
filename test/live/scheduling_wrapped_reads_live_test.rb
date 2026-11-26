# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Wrapped scheduling, registration and referral reads that had no live spec
# as their role: the scheduler's resources (BSDX RESOURCES BY USER), the
# seeded access blocks a search finds (BSDX SEARCH AVAILABILITY), and the
# appointments across resources (BSDX ALL APPOINTMENTS); the clerk's
# sensitive-record check (AGG CHECK SENSITIVE PATIENT); the provider's
# referral fiscal year (BMC CHK YEAR SITE PARAM). The writes (an appointment
# booked, cancelled, uncancelled and cancelled again) are
# SchedulingUncancelLiveTest below.
class SchedulingWrappedReadsLiveTest < LiveSpec::Test
  runs_as :scheduler

  S = RpmsRpc::Scheduling
  RESOURCE = "DEMO PRIMARY CARE"

  def test_the_scheduler_sees_the_demo_resources
    names = S.resources_by_user.map { |r| r[:name] }
    %w[DEMO\ PRIMARY\ CARE DEMO\ IHS\ CLINIC DEMO\ BEHAVIORAL\ HEALTH].each { |n| assert_includes names, n }
    primary = S.resources_by_user.find { |r| r[:name] == RESOURCE }
    assert primary[:modify_appointments], "PROFILE,SCHED may book DEMO PRIMARY CARE"
  end

  def test_a_search_finds_the_seeded_weekday_blocks
    day = Date.today + 7
    day += 1 while day.saturday? || day.sunday?
    found = S.availability(resources: RESOURCE, start_date: day, end_date: day + 6)

    refute_empty found, "SEEDBSDX lays blocks on every weekday for 8 weeks"
    found.each do |row|
      assert_equal RESOURCE, row[:resource_name]
      refute(row[:date].saturday? || row[:date].sunday?, "a block on a weekend: #{row.inspect}")
    end
    assert_includes found.map { |r| r[:date] }, day
  end
end

class SchedulingUncancelLiveTest < LiveSpec::Test
  runs_as :scheduler
  writes!

  S = RpmsRpc::Scheduling
  RESOURCE = "DEMO PRIMARY CARE"
  PATIENT = 3 # MOUSE,MICKEY M
  CLINIC_CANCELLED = "13"

  def test_a_cancelled_appointment_is_uncancelled_and_shows_in_the_day_list
    start, id = book!
    day = start.to_date
    begin
      listed = S.all_appointments(start_date: day, end_date: day)
      assert(listed.any? { |a| a[:patient_dfn] == PATIENT && a[:start_time] == start && a[:resource_name] == RESOURCE },
             "the booking at #{start} is not in BSDX ALL APPOINTMENTS for #{day}")

      assert S.cancel_appointment(id, reason: CLINIC_CANCELLED, type: "C", note: "live spec")[:success]
      refute(S.all_appointments(start_date: day, end_date: day).any? { |a| a[:patient_dfn] == PATIENT && a[:start_time] == start },
             "a cancelled appointment is still listed")

      assert_equal({ success: true }, S.uncancel_appointment(id))
      assert(S.all_appointments(start_date: day, end_date: day).any? { |a| a[:patient_dfn] == PATIENT && a[:start_time] == start },
             "the uncancelled appointment is not listed again")
    ensure
      S.cancel_appointment(id, reason: CLINIC_CANCELLED, type: "C", note: "live spec") if id
    end
  end

  private

  def book!
    40.times do
      day = Date.today + 14 + rand(21)
      day += 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 8 + rand(8), [ 0, 20, 40 ].sample(random: LiveSpec.random))
      reply = S.add_appointment(patient_dfn: PATIENT, resource: RESOURCE, start_time: start, end_time: start + 1200, length_minutes: 20)
      return [ start, reply[:appointment_id] ] if reply && reply[:success]
    end
    flunk "no weekday two to five weeks out took a booking for DFN #{PATIENT} on #{RESOURCE}"
  end
end

# AGG CHECK SENSITIVE PATIENT as the clerk: no panel patient is sensitive.
# SENS may audit the lookup when DI AUDIT PATIENT LOOKUPS is set, so the
# spec declares writes!.
class AggSensitiveCheckLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  writes!

  def test_a_panel_patient_is_not_sensitive
    assert_equal({ sensitive_indicator: 0 }, RpmsRpc::Agg.check_sensitive_patient(dfn: 990_017))
  end
end

# BMC CHK YEAR SITE PARAM answers the division's RCIS SITE PARAMETERS
# (#90001.31) fiscal year, .02, the same value DDR reads from the entry of
# the demo division (#4 7819).
class ReferralYearSiteParamLiveTest < LiveSpec::Test
  runs_as :provider

  def test_the_referral_year_is_the_site_parameter
    stored = RpmsRpc::DdrFileman.gets_entry(file: "90001.31", iens: "7819,", fields: ".02", flags: "I")
    year = stored.dig(:fields, ".02", :internal)
    refute_empty year.to_s, "the demo division has no RCIS SITE PARAMETERS year"

    assert_equal({ success: true, message: year, raw: year }, RpmsRpc::Referral.check_year_site_param)
  end
end
