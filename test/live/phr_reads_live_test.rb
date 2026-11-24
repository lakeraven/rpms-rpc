# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/phr"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/scheduling"

# The reads rpms-rpc#221 found mapped wrong, each proven on a real build as
# the provider: PHR^BEHOCCD answers ACCESS^DATE for the latest PHR answer,
# GETREF^BEHOCCD takes the visits as a list and answers each V REFERRAL,
# APPTLST^ORWPT answers each appointment's time as well as its date, and
# HSLIST^BQIRHSR answers IEN^NAME. The spec files a PHR answer, an RCIS
# referral and its V REFERRAL, and an appointment, so it runs on a disposable
# container only.
class PhrReadsLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 4 # DEMO,PATIENT ONE on the pinned build
  VISIT = 2 # a visit of DFN 4 on the pinned build
  BOOKED = 3 # MOUSE,MICKEY M, on every demo build
  CLINIC = "DEMO IHS CLINIC"
  PHR_ACCESS = "9000001.8801"

  def fileman(date) = format("%<y>03d%<m>02d%<d>02d", y: date.year - 1700, m: date.month, d: date.day)

  def file!(what, rows, iens = {})
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows, iens: iens)
    assert filed && filed[:success], "DDR FILER could not file #{what}: #{filed.inspect}"
    filed[:iens][1]
  end

  # A PHR ACCESS DATE entry is keyed by its date (DINUM); .02 is 1 YES, 0 NO.
  def answer_phr(date, access)
    day = fileman(date)
    rows = { ".01" => day, ".02" => access }.map { |f, v| { file: PHR_ACCESS, field: f, iens: "+1,#{DFN},", value: v } }
    file!("a PHR answer for DFN #{DFN}", rows, { 1 => day })
  end

  # Yesterday the patient said YES; today, NO. Each read answers the latest.
  # The entries are keyed by date, so a second run needs a new container.
  def test_enrollment_status_reads_the_latest_answer_and_its_date
    answer_phr(Date.today - 1, "1")
    status = RpmsRpc::Phr.enrollment_status(DFN)
    assert_equal [ true, true, Date.today - 1 ], status.values_at(:enrolled, :has_access, :answered_on), status.inspect

    answer_phr(Date.today, "0")
    status = RpmsRpc::Phr.enrollment_status(DFN)
    assert_equal [ false, false, Date.today ], status.values_at(:enrolled, :has_access, :answered_on), status.inspect
  end

  def test_referrals_for_visits_lists_each_v_referral_on_the_visits
    number = "9#{Time.now.to_i}"[0, 13]
    referral = file!("an RCIS referral", { ".01" => fileman(Date.today), ".02" => number, ".03" => DFN.to_s, ".04" => "N",
                                           ".14" => "O", ".15" => "A" }.map { |f, v| { file: "90001", field: f, iens: "+1,", value: v } })
    file!("a V REFERRAL", { ".01" => "3457005", ".02" => DFN.to_s, ".03" => VISIT.to_s, ".06" => referral }
                          .map { |f, v| { file: "9000010.59", field: f, iens: "+1,", value: v } })

    rows = RpmsRpc::Phr.referrals_for_visits([ 1, VISIT ])

    mine = rows.find { |r| r[:referral_ien] == referral.to_i }
    assert mine, "the V REFERRAL on visit #{VISIT} is listed: #{rows.inspect}"
    assert_equal [ VISIT, DFN, "ACTIVE", number ], mine.values_at(:visit_ien, :patient_ien, :status, :referral_number)
  end

  def test_an_appointment_tomorrow_is_listed_with_its_time
    day = Date.today + 1
    start = nil
    40.times do
      at = Time.new(day.year, day.month, day.day, 8 + rand(9), [ 0, 15, 30, 45 ].sample)
      booked = RpmsRpc::Scheduling.add_appointment(patient_dfn: BOOKED, resource: CLINIC, start_time: at,
                                                   end_time: at + 900, length_minutes: 15)
      break start = at if booked && booked[:success]
    end
    flunk "no time tomorrow took a booking for DFN #{BOOKED} on #{CLINIC}" unless start

    rows = client.with_context("CIAV VUECENTRIC") { RpmsRpc::Encounter.for_patient(BOOKED) }

    assert(rows.any? { |r| r[:datetime] == start && r[:location] == CLINIC }, "#{start} on #{CLINIC} in #{rows.inspect}")
  end

  def test_health_summary_types_are_ien_and_name
    types = RpmsRpc::Referral.health_summary_types

    refute_empty types
    types.each do |t|
      assert_equal %i[ien name], t.keys
      assert_match(/\A\d+\z/, t[:ien])
      refute_empty t[:name].to_s
    end
  end
end
