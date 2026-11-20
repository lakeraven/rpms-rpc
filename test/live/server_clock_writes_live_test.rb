# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/server_clock"
require "rpms_rpc/api/patient_application"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/agg"
require "securerandom"

# rpms-rpc#741: the write paths judge "today" and "the future" by the RPMS
# server's clock (ORWU DT "NOW"), not by this process's.
#
# Each test first moves this process's clock a whole day away from the
# server's (TZ set 24 hours off the server's offset from UTC, restored after),
# so the host's Date.today is never the server's. That is the evening case: an
# app host in UTC is already tomorrow during a US site's evening. Then:
# - a date the server counts as today is accepted, and its tomorrow refused;
# - a date the gem defaults or stamps is the server's day.
# A gem that read Date.today fails at least one of these in either direction.
#
# WRITES against a disposable local container only.
class ServerClockWritesLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk
  writes!

  REG_DFN = 990_021   # a synthetic seed patient no other live spec writes to
  VITAL_DFN = 2
  LOCATION_IEN = 6
  QUARTER_HOUR = 15 * 60

  PA = RpmsRpc::PatientApplication
  Reg = RpmsRpc::Registration
  FM = RpmsRpc::FilemanDateParser

  def test_s_reg_03_3_an_application_is_judged_and_stamped_by_the_servers_day
    type = PA.types.find { |t| t[:name] == "MEDICAID FORM 100" }
    refute_nil type, "PATIENT APPLICATION TYPES has no MEDICAID FORM 100 (run openrpms SEEDAPPT)"

    dfn = register_applicant!
    assert_equal({ ".16" => "" }, fields("9000001", "#{dfn},", ".16"), "a patient registered just now has no .16 stamp yet")

    on_a_host_a_day_off do |today|
      assert_equal :invalid, PA.add(dfn, obtained: today + 1, type: type[:ien])[:error],
                   "the server's tomorrow is in the future"

      added = PA.add(dfn, obtained: today, type: type[:ien], submitted: today, received_by: client.duz.to_i)
      assert added[:success], "the server's today is not in the future: #{added.inspect}"
      assert_equal({ ".03" => fm(today), ".16" => fm(today) }, fields("9000001", "#{dfn},", ".03;.16"),
                   "UPDATE1^AGED's stamp is the server's day")

      assert_equal({ success: true, dated: true }, PA.update_status(dfn, application: added[:application], status: "A"))
      status = PA.for_patient(dfn).find { |a| a[:ien] == added[:application] }[:submissions].first[:statuses].last
      assert_equal({ date: today, status: "A" }, status.slice(:date, :status), "an omitted status date is the server's today")
    end
  end

  def test_s_reg_sogi_and_legal_sex_default_to_the_servers_day
    gender_identity = pick_ien("9999999.104")
    orientation = pick_ien("9999999.103")
    source = pick_ien("9000030")

    on_a_host_a_day_off do |today|
      assert_equal({ success: true }, Reg.set_gender_identity(REG_DFN, values: [ gender_identity ]))
      assert dated_row?("9000001.9401", REG_DFN, today), "no gender identity row on the server's day #{today}"

      assert_equal({ success: true }, Reg.set_sexual_orientation(REG_DFN, values: [ orientation ]))
      assert dated_row?("9000001.9301", REG_DFN, today), "no sexual orientation row on the server's day #{today}"

      assert Reg.set_legal_sex(REG_DFN, sex: "X", source: source)[:success]
      assert_equal({ "1" => "X", "3" => fm(today) }, fields("9000001.9201", "#{fm(today)},#{REG_DFN},", "1;3"),
                   "the legal sex row is on the server's day, and DATE ENTERED is that day")
    end
  end

  def test_s_reg_21_7_a_date_moved_after_the_servers_today_files_nothing
    on_a_host_a_day_off do |today|
      before = Reg.address_history(REG_DFN).size

      assert_equal :invalid, Reg.change_address(REG_DFN, moved_on: today + 1, address_line1: "99 NEVER RD")[:error]
      assert_equal before, Reg.address_history(REG_DFN).size
    end
  end

  def test_s_tri_02_1_vitals_given_no_time_are_filed_at_the_servers_now
    visit_at = server_now - (rand(30..3000) * 86_400)
    made = RpmsRpc::Encounter.create(VITAL_DFN, location_ien: LOCATION_IEN, service_category: "A", create: 1,
                                                datetime: FM.format_datetime(visit_at))
    flunk "Encounter.create answered #{made.inspect}" unless made[:success]
    vstr = RpmsRpc::Encounter.visit_string(LOCATION_IEN, visit_at, "A", visit_ien: made[:visit_ien])

    on_a_host_a_day_off do |today|
      saved = RpmsRpc::Vital.add(VITAL_DFN, vstr, [ { abbreviation: "WT", value: "170", units: "" } ], provider_duz: client.duz)
      assert saved[:success], saved.inspect

      row = Array(RpmsRpc::Measurement.for_visit(made[:visit_ien])).find { |m| m[:type] == "WT" }
      refute_nil row, "no WT on visit #{made[:visit_ien]}"
      taken = fields("9000010.01", "#{row[:measurement_ien]},", "1201")["1201"]
      assert_equal fm(today), taken.split(".").first, "EVENT DATE AND TIME is on the server's day"
    end
  end

  private

  # A synthetic patient registered for this run, with no application yet.
  # A patient holds one application per date obtained, and this spec must
  # file on the server's today, so a fixed patient refused every later run on
  # that container that day (#865). There is no supported patient-delete RPC:
  # discard the container.
  def register_applicant!
    suffix = SecureRandom.hex(5).tr("0-9", "G-P").upcase
    attrs = { name_last: "ZZCLOCK#{suffix}", name_first: "DEMO", dob: free_birth_date(suffix), sex: "F", no_ssn_reason: "N" }
    result = Reg.with_lookup_client(lookup_client) { Reg.register(attrs) }
    assert result && result[:success], "could not register a synthetic applicant: #{result.inspect}"
    assert_empty PA.for_patient(result[:dfn]), "a patient registered just now already has an application"
    result[:dfn]
  end

  # A 1904 birth date no DEMO patient holds: AG's duplicate lookup matches a
  # candidate on the date and first name.
  def free_birth_date(suffix)
    dob = Date.new(1904, 1 + rand(12), 1 + rand(28))
    365.times do
      found = RpmsRpc.with_client(lookup_client) do
        RpmsRpc::Agg.registration_candidates("AGGPTLNM" => "ZZCLOCK#{suffix}", "AGGPTFNM" => "DEMO",
                                             "AGGPTDOB" => dob.strftime("%m/%d/%Y"))
      end
      flunk "AG gave no answer looking up candidates for ZZCLOCK#{suffix}" if found.nil?
      return dob if found.empty?

      dob = dob.next_day
    end
    flunk "no free synthetic 1904 birth date for ZZCLOCK#{suffix}"
  end

  def fm(date) = FM.to_fileman(date)

  def server_now = RpmsRpc::ServerClock.now

  # Runs the block with this process's TZ a whole day off the server's clock,
  # and yields the server's today. The offset is 24 hours ahead of the
  # server's when that fits POSIX's 24-hour limit, else 24 hours behind.
  def on_a_host_a_day_off
    saved = ENV.fetch("TZ", nil)
    wall = server_now
    utc = Time.now.utc
    as_utc = Time.utc(wall.year, wall.month, wall.day, wall.hour, wall.min, wall.sec)
    server_offset = ((as_utc - utc) / QUARTER_HOUR).round * QUARTER_HOUR
    host_offset = server_offset <= 0 ? server_offset + 86_400 : server_offset - 86_400
    ENV["TZ"] = posix_zone(host_offset)
    today = wall.to_date
    refute_equal today, Date.today, "this process's clock is still on the server's day (TZ=#{ENV['TZ']})"
    yield today
  ensure
    ENV["TZ"] = saved
  end

  # POSIX TZ counts hours WEST of UTC, so an offset east is written negative.
  def posix_zone(offset)
    sign = offset.positive? ? "-" : "+"
    hours, rest = offset.abs.divmod(3600)
    format("HOST%s%02d:%02d", sign, hours, rest / 60)
  end

  def fields(file, iens, list)
    reply = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: list, flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply for #{file} #{iens}"
    refute reply[:error], "no #{file} entry #{iens}"
    reply[:fields].transform_values { |v| v[:internal] }
  end

  def pick_ien(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IP", max: 5)
    refute_nil listed, "DDR LISTER gave no reply for #{file}"
    refute listed[:error], "DDR LISTER refused #{file}"
    refute_empty listed[:entries], "#{file} is empty on this build"
    listed[:entries].first[:ien].to_i
  end

  def dated_row?(file, dfn, day)
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{dfn},", fields: ".01", flags: "IP")
    refute_nil listed, "DDR LISTER gave no reply for #{file}"
    refute listed[:error], "DDR LISTER refused #{file}"
    listed[:entries].any? { |e| e[:pieces].first.to_s == fm(day) }
  end
end
