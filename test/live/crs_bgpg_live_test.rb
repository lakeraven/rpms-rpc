# frozen_string_literal: true

require_relative "live_helper"
require_relative "free_ssn"
require "rpms_rpc/api/crs"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"
require "securerandom"
require "date"

# RpmsRpc::Crs over the wire: the CRS National GPRA report and patient lists
# through the Visual CRS RPCs (`BGPG 25 ...`, context BGPGRPC), on a disposable
# twin of the pinned build (rpms-rpc#920).
#
# Who runs it. The BGPG 25 RPCs are registered under BGPGRPC and nowhere else,
# and no persona on bcer-9.0-20261119-f67498c-ydb has BGPGRPC on its menu tree:
# the provider, the front desk clerk and PROVIDER,TEST bind it and are refused
# "4 Access denied for remote procedure" over CIA (CIANBACT checks
# $$CHK^XQCS(DUZ,OPT) before it builds a context, rpms-ops#820) and refused the
# bind outright over BMX. Only the operator, who holds XUPROGMODE, can call
# them, so this spec runs as :operator (ROLE=operator RPMS_VERIFY=<the build's
# operator verify code>). Patients, visits and problems are still filed as the
# roles whose work they are (the clerk registers, the provider sees), on
# sessions of their own.
#
# Which broker. CIA. Visual CRS is a BMX client, but ONTL^BGPXGR ends its
# array with $C(31)_$G(X) where X is the routine's trap label, so over BMX
# every BGPG 25 GET NATIONAL GPRA reply ends "\x1FMERR^BGPXGU" and BmxClient
# reads it as a query error; over CIA the client stops at $C(31). The seeding
# APIs (Registration.register, Encounter.save, Problem.add) are CIA too.
#
# What the twin lacks. The image ships no community taxonomy (file 9999999.05
# has no TAXONOMY) and no BGP SITE PARAMETERS entry, and CRS cannot queue a
# report without both. They are seeded here through stock RPCs: BQI UPDATE
# COMM TAXONOMY (iCare's community-taxonomy filer; the TAXONOMY .01 input
# transform needs ATXFLG, so DDR FILER cannot add one) and BGPG 25 SAVE SITE
# PARAMETERS. Each seed is read back through the gem.
#
# The report runs through TaskMan. Before queuing, the spec reads TaskMan's
# heartbeat (^%ZTSCH("RUN") against $H, through XWB GET VARIABLE VALUE) and
# fails naming TaskMan when it is stale.
#
# WRITES against a disposable local container only.
class CrsBgpgLiveTest < LiveSpec::Test
  runs_as :operator
  writes!
  include FreeSsn

  Crs = RpmsRpc::Crs

  TAXONOMY_NAME = "SYNTH CRS COMMUNITIES"
  COMMUNITY_FILE = "9999999.05"
  COMMUNITY = "FAIRHOPE" # a standard-table community the synthetic patient lives in
  CLINIC_FILE = "44"
  CLINIC = "DEMO PRIMARY CARE" # clinic code 13, a CRS 2025 primary and secondary clinic
  ICD = "E11.9" # in taxonomy SURVEILLANCE DIABETES, which Diabetes Prevalence reads
  SNOMED = "44054006" # Type 2 diabetes mellitus; $$CONC^AUPNSICD maps it to E11.9
  DIABETES_PREVALENCE = 1 # BGP 25 INDICATORS ien
  DIABETES_DX_EVER = 1 # BGP 25 NATIONAL PATIENT LISTS ien: 001.A.1 Diabetes DX Ever
  BASELINE_YEAR = 2010
  TASKMAN_STALE_AFTER = 300 # seconds since ^%ZTSCH("RUN") before TaskMan counts as down
  REPORT_WAIT = Integer(ENV.fetch("CRS_REPORT_WAIT", "900")) # seconds to wait for the lists
  CONTEXT_ICARE = "BQIRPC"
  FS = "\x1c" # $C(28), between NAME=VALUE pairs of BQI UPDATE COMM TAXONOMY
  GS = "\x1d" # $C(29), around each community of AMQQCOMM

  def teardown
    @sessions&.each_value(&:disconnect)
    super
  end

  # --- Scenario: Site parameters name the community taxonomy -----------------

  def test_site_parameters_name_the_location_and_community_taxonomy_of_the_signed_on_division
    taxonomy = seed_crs_configuration!

    entries = Crs.site_parameters

    refute_empty entries, "BGPG 25 GET SITE PARAMETERS answered no entry for division #{division[:ien]} after seeding"
    entries.each do |entry|
      assert_operator entry.dig(:location, :ien).to_i, :>, 0, "an entry without a location: #{entry.inspect}"
      refute_empty entry.dig(:location, :name).to_s, entry.inspect
      refute_nil entry[:community_taxonomy], "an entry without a community taxonomy: #{entry.inspect}"
      assert_operator entry.dig(:community_taxonomy, :ien).to_i, :>, 0, entry.inspect
      refute_empty entry.dig(:community_taxonomy, :name).to_s, entry.inspect
    end
    mine = entries.find { |e| e.dig(:location, :ien) == division[:ien] }
    refute_nil mine, "no entry for the signed-on division #{division.inspect}: #{entries.inspect}"
    assert_equal taxonomy[:ien], mine.dig(:community_taxonomy, :ien), "the division's taxonomy is the one seeded"
    assert_equal taxonomy[:name], mine.dig(:community_taxonomy, :name)
    assert_equal({ taxonomy_ien: taxonomy[:ien], warnings: [] }, Crs.community_taxonomy(taxonomy[:ien]),
                 "CHK COMM TAX NTL finds every community of the taxonomy in the standard table")
  end

  # --- Scenario: The National GPRA patient lists run and return patients -------

  def test_the_national_gpra_patient_lists_run_and_list_the_seeded_patient
    taskman_running!
    taxonomy = seed_crs_configuration!
    patient = seed_diabetic_patient!
    name = "SYNTH NPL #{Time.now.utc.strftime('%H%M%S')}"

    queued = begin
      Crs.queue_patient_lists(community_taxonomy: taxonomy[:ien], name: name, lists: { DIABETES_PREVALENCE => [ DIABETES_DX_EVER ] },
                              period: { ends: server_today }, baseline_year: BASELINE_YEAR, population: :aian)
    rescue Crs::QueueRefusedError => e
      flunk "CRS refused to file the report request on this build (#{e.message}). REPORT^BGPXUTL could not create " \
            "the BGP 25 DATA CURRENT entry although site parameters and community taxonomy #{taxonomy[:ien]} are on " \
            "file; this is the image, not the gem (bcer-9.0-20261119-f67498c-ydb). Fix or explain it in openrpms first."
    end
    report = queued[:report_ien]
    assert_operator report, :>, 0, queued.inspect

    # Scenario: A report that never finishes times out. The lists take longer
    # than a moment, so a moment's timeout names the report it gave up on.
    timed_out = assert_raises(Crs::TimeoutError) { Crs.wait_for_report(report, timeout: 0.01, interval: 0) }
    assert_includes timed_out.message, report.to_s
    assert_includes timed_out.message, name

    row = begin
      Crs.wait_for_report(report, timeout: REPORT_WAIT, interval: 5)
    rescue Crs::TimeoutError => e
      flunk "report #{report} (#{name}) did not complete in #{REPORT_WAIT}s: #{e.message}. TaskMan was alive when it was " \
            "queued (#{taskman_heartbeat.inspect}); raise CRS_REPORT_WAIT if the twin is merely slow."
    rescue Crs::ReportFailedError => e
      flunk "report #{report} (#{name}) failed: #{e.message}. If TaskMan dropped the task, ^%ZTSCH(\"RUN\") is stale: " \
            "#{taskman_heartbeat.inspect}"
    end
    assert_equal "COMPLETED", row[:status], row.inspect
    refute_nil row[:ended_at], "a completed report has an end time: #{row.inspect}"

    lines = Crs.report_output(report)
    refute_empty lines, "BGPG 25 GET NATIONAL GPRA answered no output for completed report #{report}"
    hits = lines.each_index.select { |i| lines[i].include?(patient[:name_last]) }
    refute_empty hits, "patient #{patient[:name_last]} (DFN #{patient[:dfn]}) is on none of the lists:\n#{lines.join("\n")}"
    heading = lines[0...hits.first].reverse.find { |l| l.match?(/Diabetes/i) }
    refute_nil heading, "the patient's line is not under a Diabetes measure heading:\n#{lines[[ hits.first - 15, 0 ].max..hits.first].join("\n")}"
    assert lines.any? { |l| l.match?(/Diabetes DX Ever/i) }, "the output names the list asked for (001.A.1 Diabetes DX Ever)"
  end

  # --- Scenario: A trapped M error is an error, not an empty report ------------

  # The typed raise is proven in test/rpms_rpc/api/crs_test.rb against the
  # captured MError table. What only the wire can prove is that the build
  # really answers that table: BGPG 25 GET TAXONOMIES (TAXCHK^BGPXGU) prints
  # through a device the CIA session has not opened and traps to MERR^BGPXGU.
  def test_a_trapped_m_error_arrives_as_the_merror_table_the_gem_pins
    raw = client.with_context(Crs::CONTEXT) { client.call_rpc_global_array("BGPG 25 GET TAXONOMIES", "BGPXXTCN|") }
    nodes = raw.to_s.b.byteslice(2..).to_s.split("\x1e")

    assert_equal "T00250MError", nodes[0], "ERR^BGPXGU's header; got #{raw.to_s.b.inspect[0, 200]}"
    assert_match(/\A0\|MUMPS error: /, nodes[1].to_s, "ERR^BGPXGU's one row")
    assert_includes nodes[1], "BGPX", "the M error names its CRS routine"
  end

  private

  # --- sessions ----------------------------------------------------------------

  # A CIA session signed on as another role, kept for teardown.
  def session_as(role_name)
    @sessions ||= {}
    @sessions[role_name] ||= begin
      c = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 60)
      c.connect
      c.authenticate(*pair_of(role_name))
      c
    rescue RpmsRpc::Client::ConnectionError, RpmsRpc::Client::AuthenticationError => e
      flunk "no CIA sign-on as #{role_name}: #{e.class.name.split('::').last}: #{e.message}"
    end
  end

  # The clerk's BMX session, for Registration's duplicate lookup (#609).
  def clerk_lookup_client
    @sessions ||= {}
    @sessions[:clerk_bmx] ||= begin
      port = ENV["BMX_PORT"].to_s.strip
      flunk "BMX_PORT is not set: registration runs its duplicate lookup over BMX (#609); set the twin's BMX port" if port.empty?
      bmx = RpmsRpc::BmxClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(port), timeout: 30)
      bmx.connect
      bmx.authenticate(*pair_of(:front_desk_clerk))
      bmx
    rescue RpmsRpc::Client::ConnectionError, RpmsRpc::Client::AuthenticationError => e
      flunk "no BMX sign-on as the front desk clerk: #{e.class.name.split('::').last}: #{e.message}"
    end
  end

  def division
    client.division || flunk("the operator's CIA session has no bound division")
  end

  # --- TaskMan -------------------------------------------------------------------

  # [^%ZTSCH("RUN") as $H, $H] read through XWB GET VARIABLE VALUE (VARVAL^XWBLIB).
  def taskman_heartbeat
    run = m_value('$G(^%ZTSCH("RUN"))')
    now = m_value("$H")
    { run: run, now: now }
  end

  def taskman_running!
    beat = taskman_heartbeat
    flunk "TaskMan has never run on this twin (^%ZTSCH(\"RUN\") is empty): start it (ZTM0) before this spec" if beat[:run].to_s.empty?
    age = horolog_seconds(beat[:now]) - horolog_seconds(beat[:run])
    flunk "TaskMan is not running on this twin: ^%ZTSCH(\"RUN\")=#{beat[:run]} is #{age}s behind $H=#{beat[:now]}. " \
          "A queued CRS report would never start; start TaskMan (ZTM0) first." if age > TASKMAN_STALE_AFTER
  end

  def m_value(expression)
    Array(client.call_rpc("XWB GET VARIABLE VALUE", expression)).first.to_s
  end

  def horolog_seconds(horolog)
    days, seconds = horolog.split(",", 2)
    flunk "not a $H value: #{horolog.inspect}" unless days.to_s.match?(/\A\d+\z/) && seconds.to_s.match?(/\A\d+\z/)
    (days.to_i * 86_400) + seconds.to_i
  end

  # --- CRS configuration -----------------------------------------------------------

  # The division's BGP SITE PARAMETERS entry with a community taxonomy that
  # holds COMMUNITY, seeded when absent. Returns { ien:, name: } of the taxonomy.
  def seed_crs_configuration!
    entry = Crs.site_parameters.find { |e| e.dig(:location, :ien) == division[:ien] }
    return entry[:community_taxonomy] if entry&.dig(:community_taxonomy, :ien).to_i.positive? && taxonomy_holds_community?(entry[:community_taxonomy])

    taxonomy = create_community_taxonomy!
    save_site_parameters!(taxonomy)
    taxonomy
  end

  # The taxonomy already on the division is used only when it is this spec's,
  # so a twin configured by someone else is not rewritten under them.
  def taxonomy_holds_community?(taxonomy)
    taxonomy[:name] == TAXONOMY_NAME
  end

  # BQI UPDATE COMM TAXONOMY (UPD^BQIPLCTX, option BQIRPC): $C(28)-joined
  # NAME=VALUE pairs of iCare's Community Taxonomy window; AMQQCOMM is the
  # $C(29)-wrapped communities (iens or names). Answers I00010RESULT^T01024MSG^I00010CTXIEN.
  def create_community_taxonomy!
    community = community_ien!
    parms = [ "AMQQTNAR=#{TAXONOMY_NAME}", "AMQBDSC=synthetic community taxonomy for the live specs", "AMQQCOMM=#{GS}#{community}#{GS}" ].join(FS)
    raw = client.with_context(CONTEXT_ICARE) { client.call_rpc_global_array("BQI UPDATE COMM TAXONOMY", parms) }
    nodes = raw.to_s.b.byteslice(2..).to_s.split("\x1e")
    result, message, ien = nodes[1].to_s.split("^", 3)
    flunk "BQI UPDATE COMM TAXONOMY did not file #{TAXONOMY_NAME}: #{nodes.inspect} #{message}" unless result == "1" && ien.to_i.positive?

    check = Crs.community_taxonomy(ien.to_i)
    assert_equal [], check[:warnings], "the seeded taxonomy's community is not in the standard table: #{check.inspect}"
    { ien: ien.to_i, name: TAXONOMY_NAME }
  end

  # BGPG 25 SAVE SITE PARAMETERS (SITE^BGPXGU): location|taxonomy|home location|EISS.
  # On a new entry the build answers an MError table (SITE+39^BGPXGU, BGPERR
  # undefined) after filing, so the reply is not read; the entry is read back.
  def save_site_parameters!(taxonomy)
    client.with_context(Crs::CONTEXT) do
      client.call_rpc_global_array("BGPG 25 SAVE SITE PARAMETERS", "#{division[:ien]}|#{taxonomy[:ien]}|#{division[:ien]}|0")
    end
    entry = Crs.site_parameters.find { |e| e.dig(:location, :ien) == division[:ien] }
    flunk "BGPG 25 SAVE SITE PARAMETERS filed no entry for division #{division[:ien]}" if entry.nil?
    assert_equal taxonomy[:ien], entry.dig(:community_taxonomy, :ien), "the saved entry does not point at taxonomy #{taxonomy[:ien]}: #{entry.inspect}"
  end

  def community_ien!
    listed = RpmsRpc::DdrFileman.lister(file: COMMUNITY_FILE, fields: ".01", flags: "IP", xref: "B", from: COMMUNITY[0..-2], part: COMMUNITY, max: "5")
    flunk "DDR LISTER on COMMUNITY (#{COMMUNITY_FILE}) failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first == COMMUNITY }
    flunk "no community #{COMMUNITY} in the standard community table (#{COMMUNITY_FILE})" if row.nil?
    row[:ien]
  end

  # --- the synthetic patient -----------------------------------------------------

  # A patient CRS counts in the National GPRA user population and as diabetic:
  # beneficiary 01 (AI/AN), living in COMMUNITY (the taxonomy's one member), two
  # visits in the year ending today at a primary clinic with a provider and a
  # diabetes diagnosis (ACTUP/ACTCL/V2 in BGPXD1), and the diagnosis on the
  # problem list with an onset before the period (FIRSTDM/PLTAXNDR). Registered
  # by the front desk clerk; seen by the provider.
  def seed_diabetic_patient!
    attrs = { name_last: "ZZCRS#{SecureRandom.hex(3).tr('0-9', 'G-P').upcase}", name_first: "SYNTH", dob: Date.new(1965, 3, 14),
              sex: "F", no_ssn_reason: "N", classification: 1, community_ien: community_ien!, community_since: :birth }
    clerk = session_as(:front_desk_clerk)
    lookup = clerk_lookup_client
    registered = RpmsRpc.with_client(clerk) { RpmsRpc::Registration.with_lookup_client(lookup) { RpmsRpc::Patient.register(attrs) } }
    flunk "Patient.register did not create the synthetic patient: #{registered.inspect}" unless registered && registered[:success]
    dfn = registered[:dfn]

    provider = session_as(:provider)
    RpmsRpc.with_client(provider) do
      clinic = clinic_ien!
      today = server_today
      [ 95, 40 ].each do |days_ago|
        day = today - days_ago
        saved = RpmsRpc::Encounter.save(dfn, location_ien: clinic, datetime: Time.new(day.year, day.month, day.day, 10, 0, 0),
                                        service_category: "A", provider_duz: provider.duz,
                                        diagnoses: [ { icd: ICD, snomed: SNOMED, narrative: "SYNTH type 2 diabetes", primary: true } ])
        flunk "Encounter.save on #{day} did not file the visit with its diagnosis: #{saved.inspect}" unless saved[:success]
      end
      added = RpmsRpc::Problem.add(dfn, { icd_code: ICD, description: "SYNTH type 2 diabetes", location_ien: division[:ien],
                                          status: "Chronic", onset_date: "01/15/2019" })
      flunk "Problem.add did not file #{ICD}: #{added.inspect}" unless added[:success]
    end
    attrs.merge(dfn: dfn)
  end

  def clinic_ien!
    listed = RpmsRpc::DdrFileman.lister(file: CLINIC_FILE, fields: ".01", flags: "IP", from: CLINIC[0..-2], part: CLINIC, max: "1")
    flunk "DDR LISTER on HOSPITAL LOCATION failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first == CLINIC }
    flunk "no #{CLINIC} in HOSPITAL LOCATION (#44): the build seeds it (SEEDCLIN); is this the pinned image?" if row.nil?
    row[:ien]
  end

  # The server's today, so the report period ends on the server's date.
  def server_today
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    (RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW did not yield a FileMan datetime: #{value.inspect}")).to_date
  end
end
