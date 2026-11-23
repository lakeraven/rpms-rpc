# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/crs"
require "rpms_rpc/retry_safety"
require "rpms_rpc/data_mapper"
require_relative "../captured_replies"

# RpmsRpc::Crs runs CRS (IHS Clinical Reporting System, BGP) through the Visual
# CRS RPC interface: the `BGPG 25 ...` RPCs, all GLOBAL ARRAY (type 4) replies
# in the BMX-ADO table layout, registered under the one option BGPGRPC
# (rpms-rpc#920). The wire pinned here is the one the pinned build's routines
# define (BGPXGU, BGPXGR, BGPXGT, BGPXGUA, BGPXGNTL, BGPXGNPL; CRS 25.1 Build 98)
# and the replies a disposable twin of bcer-9.0-20261119-f67498c-ydb gave:
#
#   request   one positional string, pieces split on "|", sub-pieces on "~"
#   reply     header node  "<T|I|D|F><5-digit width><Name>^..."  then $C(30)
#             row nodes    "value^value^..."                     then $C(30)
#             end node     $C(31) [trailer]
#   M error   a table whose header is T00250MError and whose one row is
#             "0|MUMPS error: ..." (ERR^BGPXGU, reached from MERR^BGPXGU)
#
# Over CIA, CiaClient#call_rpc_global_array returns the sequence echo, the
# $C(0) ack and the nodes up to (not including) the $C(31) end node. Over BMX,
# BmxClient#call_rpc returns the same table as lines with the header kept. The
# module takes whichever the client offers (call_rpc_global_array when the
# client has it, else call_rpc), binds BGPGRPC around every call, and parses
# both shapes into hashes.
#
# What is pinned: the exact parameter string each method builds from keyword
# arguments; the refusal of "|", "~" and "^" inside a value before anything is
# sent; the parse of each table into hashes; the typed failures (an M error
# table, a reply without its header, a refused queue, a report that errors or
# never finishes, a refused context that propagates as the client's own typed
# error) — none of them an empty list; the declared shapes; the retry-safety
# classes; the required_rpcs.json contract; and that replies captured from a
# throwaway container are on file for every RPC.
class CrsTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  # Resolved per test, so a build without the module fails every test on the
  # missing constant rather than failing the file once at load.
  def self.const_missing(name)
    return RpmsRpc::Crs if name == :Crs

    super
  end

  CONTEXT = "BGPGRPC"
  DUZ = 4 # MANAGER,SYSTEM: the only account on the build that holds BGPGRPC
  TAX = 3471 # a community taxonomy ien
  RS = "\x1e" # $C(30), after every node
  ACK = "\x00"

  SP_HEADER = "T00010BMXIEN^T00050Location^T00050Home Location^T00050Community Taxonomy^T00001EISS"
  SP_ROW = "7819^7819~DEMO IHS CLINIC^7819~DEMO IHS CLINIC^3471~SYNTH CRS COMMUNITIES^0"
  COMM_HEADER = "T00200COMMUNITIES"
  COMM_WARNING = "Warning 5010F is in the taxonomy but not in the standard community table."
  TAX_HEADER = "T00080TAXONOMIES"
  TAX_ROWS = [ "BGP MENTAL HEALTH PROV CLASS(Read Only/Tax/7)", "BGP PRIMARY CARE CLINICS(Read Only/Tax/40.7)",
               "SURVEILLANCE ILI CLINICS(Editable/Tax/40.7)", "BGP ANTI-PLATELET DRUGS(Editable/Med/50)",
               "BGP CD4 TAX(Editable/Lab/60)" ].freeze
  GI_HEADER = "T00007BMXIEN^T00050Measure"
  GI_ROWS = [ "1^Diabetes Prevalence", "3^Diabetes: Glycemic Control",
              "107^Statin Therapy to Reduce Cardiovascular Disease Risk in Patients with Diabetes" ].freeze
  DATA_HEADER = "T00250DATA"
  CHK_HEADER = "T00007BMXIEN^T00060Name^T00030User^T00030Start Time^T00030End Time^T00030Type of Report^" \
               "T00020Report Status^T00020Type of Output^T00250Export File(s)^T00020Start Time Internal^T00020End Time Internal"
  MERROR_HEADER = "T00250MError"
  MERROR_ROW = "0|MUMPS error: \"150373850,SITE+39^BGPXGU,%YDB-E-LVUNDEF, Undefined local variable: BGPERR <UNDEFINED>\""

  RPCS = {
    site_parameters: "BGPG 25 GET SITE PARAMETERS",
    community_taxonomy: "BGPG 25 CHK COMM TAX NTL",
    taxonomies: "BGPG 25 GET TAXONOMY",
    indicators: "BGPG 25 GPRA INDICATORS",
    queue_national_gpra: "BGPG 25 NATIONAL GPRA RPT NTL",
    queue_patient_lists: "BGPG 25 NATIONAL GPRA LISTS",
    report_status: "BGPG 25 CHECK REPORT STATUS",
    report_output: "BGPG 25 GET NATIONAL GPRA"
  }.freeze

  # --- the wire, as CiaClient#call_rpc_global_array hands it back -------------

  # A GLOBAL ARRAY reply over CIA: sequence echo, ack, header and rows each
  # ending in $C(30); the $C(31) end node is already dropped by the client.
  def blob(header, *rows, seq: "5")
    "#{seq}#{ACK}#{header}#{RS}#{rows.map { |r| "#{r}#{RS}" }.join}".b
  end

  def m_error_blob = blob(MERROR_HEADER, MERROR_ROW)

  def chk_row(ien:, name:, status:, start: "3261123.0918", finish: "", type: "CRS 25 NPL", output: "P", user: "MANAGER,SYSTEM")
    start_ext = start.empty? ? "" : "11/23/2026 09:18"
    end_ext = finish.empty? ? "" : "11/23/2026 09:31"
    [ ien, name, user, start_ext, end_ext, type, status, output, "", start, finish ].join("^")
  end

  # --- fake twins --------------------------------------------------------------

  # A CIA-shaped client: GLOBAL ARRAY replies as raw blobs, with_context
  # recorded, every call recorded. A reply may be a Proc of the params, a
  # blob, or an exception to raise. No call_rpc: a module that falls back to
  # it on a client that offers call_rpc_global_array has read the wrong wire.
  class FakeTwin
    attr_reader :calls, :binds

    def initialize(replies = {})
      @replies = replies
      @calls = []
      @binds = []
    end

    def duz = DUZ.to_s

    def with_context(option)
      @binds << option
      yield
    end

    def call_rpc_global_array(rpc, *params)
      @calls << [ rpc, params ]
      reply = @replies.fetch(rpc) { raise "FakeTwin: no reply for #{rpc}" }
      reply = reply.call(params, @calls.count { |c| c.first == rpc }) if reply.respond_to?(:call)
      raise reply if reply.is_a?(Exception) || (reply.is_a?(Class) && reply < Exception)

      reply.is_a?(String) ? RpmsRpc::Reply.text(reply) : reply
    end

    def sent(rpc) = @calls.select { |c| c.first == rpc }.map(&:last)
  end

  # A BMX-shaped client: the same tables as lines, header kept, separators
  # stripped (BmxClient#call_rpc). No call_rpc_global_array.
  class LinesTwin
    attr_reader :calls

    def initialize(replies = {})
      @replies = replies
      @calls = []
    end

    def duz = DUZ.to_s

    def call_rpc(rpc, *params)
      @calls << [ rpc, params ]
      RpmsRpc::Reply.from_wire(@replies.fetch(rpc) { raise "LinesTwin: no reply for #{rpc}" })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def twin(replies = {})
    RpmsRpc.reset!
    client = FakeTwin.new(replies)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def lines_twin(replies = {})
    RpmsRpc.reset!
    client = LinesTwin.new(replies)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def queue_lists(**overrides)
    args = { community_taxonomy: TAX, name: "SYNTH NPL", lists: { 1 => [ 1 ] },
             period: { ends: Date.new(2026, 11, 23) }, baseline_year: 2010, population: :aian }.merge(overrides)
    Crs.queue_patient_lists(**args)
  end

  # --- the API surface ---------------------------------------------------------

  def test_the_module_offers_the_methods_the_issue_names_and_binds_bgpgrpc
    assert_equal CONTEXT, Crs::CONTEXT
    %i[site_parameters community_taxonomy taxonomies indicators queue_national_gpra queue_patient_lists
       report_status report_output wait_for_report].each do |name|
      assert Crs.respond_to?(name), "RpmsRpc::Crs.#{name} must be a public method"
    end
  end

  def test_every_read_is_sent_under_bgpgrpc_through_the_global_array_reader
    client = twin(RPCS[:site_parameters] => blob(SP_HEADER, SP_ROW), RPCS[:indicators] => blob(GI_HEADER, *GI_ROWS),
                  RPCS[:taxonomies] => blob(TAX_HEADER, *TAX_ROWS), RPCS[:community_taxonomy] => blob(COMM_HEADER),
                  RPCS[:report_status] => blob(CHK_HEADER), RPCS[:report_output] => blob(DATA_HEADER, "line"))

    Crs.site_parameters
    Crs.indicators
    Crs.taxonomies
    Crs.community_taxonomy(TAX)
    Crs.report_status
    Crs.report_output(12)

    assert_equal [ CONTEXT ] * 6, client.binds, "each call binds BGPGRPC (ContextScope) and restores afterwards"
    assert_equal 6, client.calls.size
  end

  # --- parameter strings -------------------------------------------------------

  def test_site_parameters_sends_an_empty_site_for_the_signed_on_division_or_the_location_given
    client = twin(RPCS[:site_parameters] => blob(SP_HEADER, SP_ROW))

    Crs.site_parameters
    Crs.site_parameters(location: 7819)

    assert_equal [ [ "" ], [ "7819" ] ], client.sent(RPCS[:site_parameters]),
                 "SP^BGPXGU: piece 1 empty means DUZ(2), digits are a LOCATION (#4) ien"
  end

  def test_community_taxonomy_sends_the_taxonomy_ien_alone
    client = twin(RPCS[:community_taxonomy] => blob(COMM_HEADER, COMM_WARNING))

    Crs.community_taxonomy(TAX)
    Crs.community_taxonomy(TAX.to_s)

    assert_equal [ [ TAX.to_s ], [ TAX.to_s ] ], client.sent(RPCS[:community_taxonomy])
  end

  def test_community_taxonomy_refuses_anything_but_a_positive_integer_before_sending
    client = twin(RPCS[:community_taxonomy] => blob(COMM_HEADER))

    # COMCHK^BGPXGUA reads piece 1 as a TAXONOMY (#9002226) ien and quits
    # (`Q 0`, inside a DO) for a blank, non-numeric or unknown one; live, the
    # pinned build answered the bare header for "" and "abc". Neither is an
    # answer about a taxonomy, so the gem refuses before sending.
    [ nil, "", "0", 0, -3, "SYNTH CRS COMMUNITIES", "3471|1", "3471~1", "3471^1" ].each do |bad|
      assert_raises(ArgumentError, "taxonomy #{bad.inspect} must be refused") { Crs.community_taxonomy(bad) }
    end
    assert_empty client.calls
  end

  def test_taxonomies_asks_for_the_crs_package_and_indicators_for_the_national_gpra_set
    client = twin(RPCS[:taxonomies] => blob(TAX_HEADER, *TAX_ROWS), RPCS[:indicators] => blob(GI_HEADER, *GI_ROWS))

    Crs.taxonomies
    Crs.indicators

    assert_equal [ [ "BGP" ] ], client.sent(RPCS[:taxonomies]), "GETTAX^BGPXGT: the package namespace, looked up in ^DIC(9.4,\"C\")"
    assert_equal [ [ "1" ] ], client.sent(RPCS[:indicators]), "GI^BGPXGT: report type 1 is the National GPRA measure set"
  end

  def test_queue_national_gpra_builds_the_ten_piece_ntl_string_from_keywords
    client = twin(RPCS[:queue_national_gpra] => blob(DATA_HEADER, "12"))

    result = Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL")

    # NTL^BGPXGR: 1 taxonomy, 2 export to Area, 3 output P/D/B, 4 ignored,
    # 5 run time ("" = now), 6 MFI, 7 unused, 8 one/many ht-wt files,
    # 9 the report NAME (.01 of BGP 25 GUI REPORT OUTPUT), 10 log.
    assert_equal [ [ "#{TAX}|0|P||||||SYNTH NTL|" ] ], client.sent(RPCS[:queue_national_gpra])
    assert_equal 12, result[:report_ien]
    assert_equal "12", result[:raw]
  end

  def test_queue_national_gpra_options_land_in_their_pieces
    client = twin(RPCS[:queue_national_gpra] => blob(DATA_HEADER, "13"))

    Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL", export_to_area: true, output: :both,
                            run_at: Time.new(2026, 11, 23, 22, 30, 0))

    assert_equal [ [ "#{TAX}|1|B||3261123.2230||||SYNTH NTL|" ] ], client.sent(RPCS[:queue_national_gpra]),
                 "export 1, output B, run time as a FileMan date.time in piece 5"
  end

  def test_queue_patient_lists_builds_the_npl_string_for_a_user_defined_period
    client = twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "21"))

    result = queue_lists

    # NPL^BGPXGR: 1 taxonomy, 2 period (end date for quarter 5), 3 provider
    # ien~name ("~" = all), 4 output, 5 run time, 6 quarter 1-5, 7 list type
    # A/P, 8 MFI, 9 baseline year (3100000 = 2010), 10 population 1 AI/AN,
    # 11 name, 12 log, 13.. measure~list[~list].
    assert_equal [ [ "#{TAX}|3261123|~|P||5|A||3100000|1|SYNTH NPL||1~1" ] ], client.sent(RPCS[:queue_patient_lists])
    assert_equal 21, result[:report_ien]
  end

  def test_queue_patient_lists_takes_a_report_year_and_quarter_several_lists_a_provider_and_a_population
    client = twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "22"))

    queue_lists(period: { year: 2026, quarter: 4 }, lists: { 1 => [ 1 ], 3 => [ 2, 5 ] }, provider: 206, population: :all, output: :delimited)

    assert_equal [ [ "#{TAX}|3260000|206~|D||4|P||3100000|3|SYNTH NPL||1~1|3~2~5" ] ], client.sent(RPCS[:queue_patient_lists]),
                 "year 2026 is FileMan 3260000 (quarter 4: Oct 2025 - Sep 2026); a provider makes list type P; population :all is 3"
  end

  def test_queue_patient_lists_refuses_an_incomplete_request_before_sending
    client = twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "23"))

    assert_raises(ArgumentError) { queue_lists(lists: {}) }
    assert_raises(ArgumentError) { queue_lists(lists: { 1 => [] }) }
    assert_raises(ArgumentError) { queue_lists(period: {}) }
    assert_raises(ArgumentError) { queue_lists(period: { year: 2026 }) }
    assert_raises(ArgumentError) { queue_lists(period: { year: 2026, quarter: 5 }) }
    assert_raises(ArgumentError) { queue_lists(population: :everyone) }
    assert_raises(ArgumentError) { queue_lists(output: :pdf) }
    assert_raises(ArgumentError) { queue_lists(name: "") }
    assert_raises(ArgumentError) { queue_lists(name: "   ") }
    assert_raises(ArgumentError) { queue_lists(community_taxonomy: nil) }
    assert_raises(ArgumentError) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "") }
    assert_raises(ArgumentError) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "x", output: :word) }
    assert_empty client.calls, "nothing is sent for a request CRS would refuse"
  end

  def test_a_delimiter_inside_a_value_is_refused_before_anything_is_sent
    client = twin(RPCS.values.to_h { |rpc| [ rpc, blob(DATA_HEADER, "1") ] })

    bad_names = [ "SYNTH|NPL", "SYNTH~NPL", "SYNTH^NPL" ]
    bad_names.each do |name|
      assert_raises(ArgumentError, name) { queue_lists(name: name) }
      assert_raises(ArgumentError, name) { Crs.queue_national_gpra(community_taxonomy: TAX, name: name) }
    end
    assert_raises(ArgumentError) { queue_lists(community_taxonomy: "3471|0") }
    assert_raises(ArgumentError) { queue_lists(community_taxonomy: "3471~0") }
    assert_raises(ArgumentError) { queue_lists(provider: "206~PROVIDER") }
    assert_raises(ArgumentError) { queue_lists(lists: { "1|2" => [ 1 ] }) }
    assert_raises(ArgumentError) { queue_lists(lists: { 1 => [ "1~2" ] }) }
    assert_raises(ArgumentError) { Crs.site_parameters(location: "7819|1") }
    assert_raises(ArgumentError) { Crs.site_parameters(location: "7819~1") }
    assert_raises(ArgumentError) { Crs.report_output("12|1") }
    assert_raises(ArgumentError) { Crs.report_output("") }
    assert_raises(ArgumentError) { Crs.report_output(0) }
    assert_empty client.calls, "a value carrying | ~ or ^ never reaches the wire"
  end

  def test_report_status_asks_for_the_signed_on_users_reports_and_report_output_for_one_report
    client = twin(RPCS[:report_status] => blob(CHK_HEADER), RPCS[:report_output] => blob(DATA_HEADER))

    Crs.report_status
    Crs.report_output(12)
    Crs.report_output("13")

    assert_equal [ [ DUZ.to_s ] ], client.sent(RPCS[:report_status]), "CHK^BGPXGU takes the DUZ whose reports to list"
    assert_equal [ [ "12" ], [ "13" ] ], client.sent(RPCS[:report_output])
  end

  # --- parsing the tables ------------------------------------------------------

  def test_site_parameters_names_each_entrys_location_home_location_and_community_taxonomy
    twin(RPCS[:site_parameters] => blob(SP_HEADER, SP_ROW, "7820^7820~EXAMPLE SATELLITE^^^1"))

    rows = Crs.site_parameters

    assert_equal 2, rows.size
    assert_equal({ ien: 7819, location: { ien: 7819, name: "DEMO IHS CLINIC" }, home_location: { ien: 7819, name: "DEMO IHS CLINIC" },
                   community_taxonomy: { ien: 3471, name: "SYNTH CRS COMMUNITIES" }, eiss: false }, rows.first)
    assert_equal({ ien: 7820, location: { ien: 7820, name: "EXAMPLE SATELLITE" }, home_location: nil, community_taxonomy: nil, eiss: true },
                 rows.last, "an unset pointer column is empty on the wire and nil here; EISS 1 is true")
  end

  def test_site_parameters_with_no_entry_is_an_empty_list
    twin(RPCS[:site_parameters] => blob(SP_HEADER))

    assert_equal [], Crs.site_parameters, "the header alone: the division has no BGP SITE PARAMETERS entry"
  end

  def test_community_taxonomy_returns_the_warnings_crs_raises_about_the_taxonomy
    twin(RPCS[:community_taxonomy] => ->(params, _n) { params.first == "1141" ? blob(COMM_HEADER, COMM_WARNING) : blob(COMM_HEADER) })

    assert_equal({ taxonomy_ien: 1141, warnings: [ COMM_WARNING ] }, Crs.community_taxonomy(1141))
    assert_equal({ taxonomy_ien: TAX, warnings: [] }, Crs.community_taxonomy(TAX),
                 "COMCHK^BGPXGUA lists only communities missing from the standard table; a clean taxonomy has none")
  end

  def test_taxonomies_split_the_name_state_kind_and_file_out_of_each_row
    twin(RPCS[:taxonomies] => blob(TAX_HEADER, *TAX_ROWS))

    rows = Crs.taxonomies

    assert_equal TAX_ROWS.size, rows.size
    assert_equal({ name: "BGP MENTAL HEALTH PROV CLASS", read_only: true, kind: "Tax", file: "7" }, rows[0])
    assert_equal({ name: "BGP PRIMARY CARE CLINICS", read_only: true, kind: "Tax", file: "40.7" }, rows[1])
    assert_equal({ name: "SURVEILLANCE ILI CLINICS", read_only: false, kind: "Tax", file: "40.7" }, rows[2])
    assert_equal({ name: "BGP ANTI-PLATELET DRUGS", read_only: false, kind: "Med", file: "50" }, rows[3])
    assert_equal({ name: "BGP CD4 TAX", read_only: false, kind: "Lab", file: "60" }, rows[4])
  end

  def test_indicators_are_ien_and_name
    twin(RPCS[:indicators] => blob(GI_HEADER, *GI_ROWS))

    rows = Crs.indicators

    assert_equal [ { ien: 1, name: "Diabetes Prevalence" }, { ien: 3, name: "Diabetes: Glycemic Control" },
                   { ien: 107, name: "Statin Therapy to Reduce Cardiovascular Disease Risk in Patients with Diabetes" } ], rows
  end

  def test_report_status_rows_carry_the_status_and_internal_times
    twin(RPCS[:report_status] => blob(CHK_HEADER,
                                      chk_row(ien: 12, name: "SYNTH NPL", status: "RUNNING"),
                                      chk_row(ien: 13, name: "SYNTH NTL", status: "COMPLETED", finish: "3261123.0931", type: "CRS 25 NATIONAL GPRA REPORT")))

    rows = Crs.report_status

    assert_equal 2, rows.size
    running = rows.first
    assert_equal 12, running[:ien]
    assert_equal "SYNTH NPL", running[:name]
    assert_equal "MANAGER,SYSTEM", running[:user]
    assert_equal "RUNNING", running[:status]
    assert_equal "CRS 25 NPL", running[:type]
    assert_equal "P", running[:output_type]
    assert_equal Time.new(2026, 11, 23, 9, 18, 0), running[:started_at], "piece 10, the internal start time"
    assert_nil running[:ended_at], "no end time while it runs"
    done = rows.last
    assert_equal "COMPLETED", done[:status]
    assert_equal Time.new(2026, 11, 23, 9, 31, 0), done[:ended_at]
  end

  def test_report_output_is_the_lines_of_the_finished_report_with_page_breaks_kept
    twin(RPCS[:report_output] => blob(DATA_HEADER, "", "          ***  IHS 2025 National GPRA Patient List  ***", "\f", "ZZCRS,SYNTH  990057"))

    lines = Crs.report_output(12)

    assert_equal [ "", "          ***  IHS 2025 National GPRA Patient List  ***", "\f", "ZZCRS,SYNTH  990057" ], lines,
                 "ONTL^BGPXGR: one row per output line, $C(12) where the print formatter broke a page"
  end

  def test_report_output_of_a_report_with_nothing_filed_yet_is_an_empty_list
    twin(RPCS[:report_output] => blob(DATA_HEADER))

    assert_equal [], Crs.report_output(999_999)
  end

  def test_the_same_tables_parse_from_a_bmx_shaped_client_that_returns_lines
    client = lines_twin(RPCS[:site_parameters] => [ SP_HEADER, SP_ROW ], RPCS[:indicators] => [ GI_HEADER, *GI_ROWS ],
                        RPCS[:report_status] => [ CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "QUEUED") ],
                        RPCS[:queue_national_gpra] => [ DATA_HEADER, "12" ])

    assert_equal 3471, Crs.site_parameters.first.dig(:community_taxonomy, :ien)
    assert_equal [ 1, 3, 107 ], Crs.indicators.map { |r| r[:ien] }
    assert_equal "QUEUED", Crs.report_status.first[:status]
    assert_equal 12, Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL")[:report_ien]
    assert_equal 4, client.calls.size, "a client without call_rpc_global_array is read through call_rpc"
  end

  # --- typed failures, never an empty list ------------------------------------

  def test_a_trapped_m_error_table_raises_a_server_error_carrying_the_m_error_text
    twin(RPCS.values.to_h { |rpc| [ rpc, m_error_blob ] })

    error = assert_raises(Crs::ServerError) { Crs.site_parameters }
    assert_includes error.message, "SITE+39^BGPXGU", "the M error text CRS put in the MError row"
    assert_includes error.message, RPCS[:site_parameters], "the RPC that trapped"
    assert_raises(Crs::ServerError) { Crs.community_taxonomy(TAX) }
    assert_raises(Crs::ServerError) { Crs.taxonomies }
    assert_raises(Crs::ServerError) { Crs.indicators }
    assert_raises(Crs::ServerError) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL") }
    assert_raises(Crs::ServerError) { queue_lists }
    assert_raises(Crs::ServerError) { Crs.report_status }
    assert_raises(Crs::ServerError) { Crs.report_output(12) }
    assert Crs::ServerError < Crs::Error
    assert Crs::Error < RpmsRpc::Error
  end

  def test_an_m_error_table_from_a_bmx_shaped_client_is_the_same_server_error
    lines_twin(RPCS[:report_output] => [ MERROR_HEADER, MERROR_ROW ])

    error = assert_raises(Crs::ServerError) { Crs.report_output(12) }
    assert_includes error.message, "BGPXGU"
  end

  # The entry points that trap to MERR^BGPGU instead (COMCHK^BGPXGUA among
  # them) keep the table's own header and write "ERROR|MUMPS error: ..." as
  # the first row (ERR^BGPGU). Read from the routine; not reproduced live.
  def test_an_error_row_under_a_normal_header_is_the_same_server_error
    twin(RPCS[:community_taxonomy] => blob(COMM_HEADER, "ERROR|MUMPS error: \"150373090,COMCHK+12^BGPXGUA,%YDB-E-QUITARGUSE\""))

    error = assert_raises(Crs::ServerError) { Crs.community_taxonomy(TAX) }
    assert_includes error.message, "COMCHK+12^BGPXGUA"
  end

  def test_a_reply_without_its_typed_header_raises_a_reply_error
    headerless = {
      "nothing after the ack" => "5#{ACK}".b,
      "an empty reply" => "".b,
      "a bare value" => "5#{ACK}7819^7819~DEMO IHS CLINIC#{RS}".b,
      "an error line in place of a table" => "5#{ACK}-1^Bad input#{RS}".b
    }
    headerless.each do |label, raw|
      twin(RPCS[:site_parameters] => raw, RPCS[:report_output] => raw, RPCS[:report_status] => raw)

      error = assert_raises(Crs::ReplyError, label) { Crs.site_parameters }
      assert_includes error.message, RPCS[:site_parameters], label
      assert_raises(Crs::ReplyError, label) { Crs.report_output(12) }
      assert_raises(Crs::ReplyError, label) { Crs.report_status }
    end
    assert Crs::ReplyError < Crs::Error
  end

  def test_a_nil_reply_raises_a_reply_error
    twin(RPCS[:indicators] => ->(_params, _n) { nil })

    assert_raises(Crs::ReplyError) { Crs.indicators }
  end

  def test_a_refused_context_propagates_as_the_clients_typed_refusal
    # Live on the pinned build: a persona without BGPGRPC on its menu tree binds
    # the context (CIA binds lazily) and the call is refused "4 Access denied
    # for remote procedure: ...". That typed error is the answer, not [].
    refused = RpmsRpc::Client::RpcRefusedError.new("4 Access denied for remote procedure: BGPG 25 GET SITE PARAMETERS")
    twin(RPCS.values.to_h { |rpc| [ rpc, refused ] })

    assert_raises(RpmsRpc::Client::RpcRefusedError) { Crs.site_parameters }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { Crs.indicators }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { Crs.report_status }
    assert_raises(RpmsRpc::Client::RpcRefusedError) { queue_lists }

    bind_refused = RpmsRpc::Client::ContextBindRefusedError.new("Failed to create context 'BGPGRPC': User does not have access to option BGPGRPC")
    twin(RPCS.values.to_h { |rpc| [ rpc, bind_refused ] })
    assert_raises(RpmsRpc::Client::ContextBindRefusedError) { Crs.taxonomies }
  end

  def test_a_refused_queue_raises_naming_the_reason_crs_gave
    twin(RPCS[:queue_national_gpra] => blob(DATA_HEADER, "0^COULD NOT CREATE REPORT ENTRY"))

    error = assert_raises(Crs::QueueRefusedError) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL") }
    assert_includes error.message, "COULD NOT CREATE REPORT ENTRY"
    assert_includes error.message, "SYNTH NTL", "the refusal names the report"
    assert Crs::QueueRefusedError < Crs::Error
  end

  def test_a_patient_list_queue_that_answers_a_bare_zero_is_refused_too
    # NPL^BGPXGR answers +$G(BGPERR): the number only, so the reason is lost.
    twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "0"))

    error = assert_raises(Crs::QueueRefusedError) { queue_lists }
    assert_includes error.message, "SYNTH NPL"
    assert_includes error.message, RPCS[:queue_patient_lists]
  end

  def test_a_queue_reply_that_is_not_a_report_ien_is_a_reply_error
    twin(RPCS[:queue_patient_lists] => blob(DATA_HEADER, "twelve"), RPCS[:queue_national_gpra] => blob(DATA_HEADER))

    assert_raises(Crs::ReplyError) { queue_lists }
    assert_raises(Crs::ReplyError) { Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL") }
  end

  # --- waiting on a queued report ----------------------------------------------

  def test_wait_for_report_polls_report_status_until_the_report_is_completed
    client = twin(RPCS[:report_status] => lambda { |_params, n|
      blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: n < 3 ? "RUNNING" : "COMPLETED", finish: n < 3 ? "" : "3261123.0931"))
    })

    row = Crs.wait_for_report(12, timeout: 5, interval: 0)

    assert_equal "COMPLETED", row[:status]
    assert_equal 12, row[:ien]
    assert_equal 3, client.sent(RPCS[:report_status]).size, "polled through BGPG 25 CHECK REPORT STATUS until COMPLETED"
    assert_equal [ CONTEXT ] * 3, client.binds
  end

  def test_wait_for_report_accepts_the_queue_result_as_well_as_an_ien
    twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "COMPLETED", finish: "3261123.0931")))

    assert_equal 12, Crs.wait_for_report({ report_ien: 12, raw: "12" }, timeout: 1, interval: 0)[:ien]
    assert_equal 12, Crs.wait_for_report("12", timeout: 1, interval: 0)[:ien]
  end

  def test_a_report_that_never_finishes_times_out_naming_the_report
    client = twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "RUNNING")))

    error = assert_raises(Crs::TimeoutError) { Crs.wait_for_report(12, timeout: 0.05, interval: 0) }

    assert_includes error.message, "12", "the report ien"
    assert_includes error.message, "SYNTH NPL", "the report name"
    assert_includes error.message, "RUNNING", "the last status seen"
    assert_operator client.sent(RPCS[:report_status]).size, :>=, 2, "it kept polling until the timeout"
    assert Crs::TimeoutError < Crs::Error
    refute Crs::TimeoutError < RpmsRpc::Client::TimeoutError, "a report timeout is not a broker timeout"
  end

  def test_a_report_still_queued_at_the_deadline_times_out_too
    twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "QUEUED", start: "3261124.0100")))

    error = assert_raises(Crs::TimeoutError) { Crs.wait_for_report(12, timeout: 0.05, interval: 0) }
    assert_includes error.message, "QUEUED"
  end

  def test_a_report_that_errored_raises_a_report_failure_not_a_timeout
    client = twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 12, name: "SYNTH NPL", status: "ERRORED")))

    error = assert_raises(Crs::ReportFailedError) { Crs.wait_for_report(12, timeout: 5, interval: 0) }

    assert_includes error.message, "12"
    assert_includes error.message, "ERRORED"
    assert_equal 1, client.sent(RPCS[:report_status]).size, "an ERRORED report is final; no more polling"
    assert Crs::ReportFailedError < Crs::Error
  end

  def test_a_report_absent_from_the_users_reports_is_a_report_failure
    # CHK^BGPXGU deletes a report with no end time once its start is a week
    # old, and lists only the signed-on user's reports: a missing row is an
    # answer about this report, not a reason to wait.
    twin(RPCS[:report_status] => blob(CHK_HEADER, chk_row(ien: 77, name: "SOMEONE ELSES", status: "RUNNING")))

    error = assert_raises(Crs::ReportFailedError) { Crs.wait_for_report(12, timeout: 5, interval: 0) }
    assert_includes error.message, "12"
  end

  def test_wait_for_report_requires_a_timeout_and_refuses_a_bad_report
    twin(RPCS[:report_status] => blob(CHK_HEADER))

    assert_raises(ArgumentError) { Crs.wait_for_report(12) }
    assert_raises(ArgumentError) { Crs.wait_for_report(12, timeout: 0, interval: 0) }
    assert_raises(ArgumentError) { Crs.wait_for_report(nil, timeout: 1, interval: 0) }
    assert_raises(ArgumentError) { Crs.wait_for_report("12|1", timeout: 1, interval: 0) }
  end

  def test_an_m_error_while_polling_is_a_server_error_not_a_timeout
    twin(RPCS[:report_status] => m_error_blob)

    assert_raises(Crs::ServerError) { Crs.wait_for_report(12, timeout: 5, interval: 0) }
  end

  # --- declarations and contract files --------------------------------------

  SHAPES = {
    site_parameters: [ "GET", "/crs/site-parameters" ],
    community_taxonomy: [ "GET", "/crs/community-taxonomies/{taxonomy}" ],
    taxonomies: [ "GET", "/crs/taxonomies" ],
    indicators: [ "GET", "/crs/indicators" ],
    queue_national_gpra: [ "POST", "/crs/reports/national-gpra" ],
    queue_patient_lists: [ "POST", "/crs/reports/national-gpra-patient-lists" ],
    # CHK^BGPXGU deletes week-old unfinished requests while it lists, so the
    # status check and the wait that polls it are writes, and a write-class
    # method never declares GET (test/api_coverage/shape_test.rb): they are
    # actions, POSTed.
    report_status: [ "POST", "/crs/reports/status-check" ],
    report_output: [ "GET", "/crs/reports/{report_ien}/output" ],
    wait_for_report: [ "POST", "/crs/reports/{report_ien}/completion" ]
  }.freeze

  def test_each_method_declares_its_shape
    SHAPES.each do |method, (verb, path)|
      shape = RpmsRpc::Shape.for(Crs, method)

      refute_nil shape, "Crs.#{method} must declare a shape"
      assert_equal "crs", shape[:resource], method
      assert_equal verb, shape[:verb], method
      assert_equal path, shape[:path], method
    end
  end

  def test_every_method_is_classified_and_the_writes_are_not_retry_safe
    SHAPES.each_key do |method|
      cls = RpmsRpc::RetrySafety.for(Crs, method)
      assert_includes RpmsRpc::RetrySafety::CLASSES, cls, "Crs.#{method} must be in retry_safety.yml"
    end
    # Queuing files a CRS report request (BGP 25 GUI REPORT OUTPUT) and a
    # TaskMan task; CHK^BGPXGU deletes week-old unfinished requests while it
    # lists, so polling writes too.
    %i[queue_national_gpra queue_patient_lists report_status wait_for_report].each do |method|
      assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(Crs, method), method
      refute RpmsRpc::RetrySafety.auto_retry_safe?(Crs, method), method
    end
  end

  def test_a_data_mapper_entry_names_each_rpc_under_bgpgrpc
    {
      crs_site_parameters: RPCS[:site_parameters], crs_community_taxonomy_check: RPCS[:community_taxonomy],
      crs_taxonomies: RPCS[:taxonomies], crs_indicators: RPCS[:indicators],
      crs_national_gpra_queue: RPCS[:queue_national_gpra], crs_patient_lists_queue: RPCS[:queue_patient_lists],
      crs_report_status: RPCS[:report_status], crs_report_output: RPCS[:report_output]
    }.each do |name, rpc|
      mapping = RpmsRpc::DataMapper[name]

      refute_nil mapping, "DataMapper mapping :#{name} must exist"
      assert_equal rpc, mapping.rpc_name, name
      assert_equal CONTEXT, mapping.bound_context, "#{name} binds BGPGRPC, the one option these RPCs are registered in"
    end
  end

  def test_required_rpcs_json_lists_the_eight_rpcs_under_crs_with_their_methods_and_fixture
    doc = JSON.parse(File.read(File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")))
    listed = doc.fetch("modules").fetch("RpmsRpc::Crs")
    RPCS.each_value { |rpc| assert_includes listed, rpc, "required_rpcs.json must list #{rpc} under RpmsRpc::Crs (rake rpc:required_rpcs)" }

    RPCS.each do |method, rpc|
      entry = doc.fetch("rpcs").fetch(rpc)
      assert_includes entry.fetch("methods").keys, "RpmsRpc::Crs.#{method}", "#{rpc} must name Crs.#{method}: #{entry.inspect}"
      assert_includes entry.fetch("replies"), "test/fixtures/captured_replies/bgpg-crs.yml", rpc
    end
    assert_equal "non_idempotent_write", doc.fetch("rpcs").fetch(RPCS[:queue_patient_lists]).fetch("methods").fetch("RpmsRpc::Crs.queue_patient_lists")
  end

  # Replies recorded from a throwaway container of the pinned build, one per
  # RPC, by tools/capture_replies.rb (tools/captured_replies/bgpg-crs.rb). The
  # build's own trapped error (SITE^BGPXGU on a new site entry, or TAXCHK over
  # CIA) is captured too, so the MError parse is tested against the wire, not
  # against a reply we wrote.
  def test_captured_replies_for_every_rpc_and_a_trapped_m_error_are_on_file
    captures = CapturedReplies.file("bgpg-crs").fetch("captures") # fails on a broken seal
    recorded = captures.map { |c| c["rpc"] }.uniq

    RPCS.each_value { |rpc| assert_includes recorded, rpc, "bgpg-crs.yml must record #{rpc}" }
    RPCS.each_value do |rpc|
      with_header = captures.select { |c| c["rpc"] == rpc }.map { |c| c["raw_return"].to_s.b }
      assert with_header.any? { |raw| raw.match?(/[ITDF]\d{5}/) }, "#{rpc}: at least one capture carries a typed table header"
    end
    assert captures.any? { |c| c["raw_return"].to_s.b.include?(MERROR_HEADER.b) },
           "bgpg-crs.yml must record a real MERR^BGPXGU table (T00250MError), the trapped-error wire"
    # The queue captures record what the build answered. On the pinned image
    # CRS refuses every report request (REPORT^BGPXGU cannot file the BGP 25
    # DATA CURRENT entry, openrpms#1305): NPL answers the bare `0` and NTL
    # `0^COULD NOT CREATE REPORT ENTRY`. A capture that answered a report ien
    # can be recorded only once openrpms#1305 is fixed; until then the
    # refusal is the wire, and it is what the parser is tested against.
    npl = captures.select { |c| c["rpc"] == RPCS[:queue_patient_lists] }.map { |c| c["raw_return"].to_s.b }
    assert npl.any? { |raw| raw.match?(/#{DATA_HEADER}#{RS}\d+#{RS}/) },
           "bgpg-crs.yml must record a BGPG 25 NATIONAL GPRA LISTS queue answer: a report ien, or the bare 0 refusal (openrpms#1305)"
    ntl = captures.select { |c| c["rpc"] == RPCS[:queue_national_gpra] }.map { |c| c["raw_return"].to_s.b }
    assert ntl.any? { |raw| raw.match?(/#{DATA_HEADER}#{RS}(\d+|0\^[A-Z ]+)#{RS}/) },
           "bgpg-crs.yml must record a BGPG 25 NATIONAL GPRA RPT NTL queue answer: a report ien, or 0^<reason> (openrpms#1305)"
  end

  def test_the_captured_queue_refusals_raise_the_typed_refusal
    captures = CapturedReplies.file("bgpg-crs").fetch("captures")
    refused = captures.select { |c| c["raw_return"].to_s.b.match?(/#{DATA_HEADER}#{RS}0(\^[^#{RS}]*)?#{RS}/) }
    refused.each do |capture|
      twin(capture["rpc"] => capture["raw_return"].to_s.b)
      call = capture["rpc"] == RPCS[:queue_patient_lists] ? -> { queue_lists } : -> { Crs.queue_national_gpra(community_taxonomy: TAX, name: "SYNTH NTL") }

      assert_raises(Crs::QueueRefusedError, capture["name"]) { call.call }
    end
  end

  def test_the_captured_trapped_error_parses_as_a_server_error_and_the_captured_tables_parse_as_rows
    captures = CapturedReplies.file("bgpg-crs").fetch("captures")
    m_error = captures.find { |c| c["raw_return"].to_s.b.include?(MERROR_HEADER.b) }
    refute_nil m_error

    twin(RPCS[:site_parameters] => m_error["raw_return"].to_s.b)
    assert_raises(Crs::ServerError) { Crs.site_parameters }

    status = captures.find { |c| c["rpc"] == RPCS[:report_status] }
    twin(RPCS[:report_status] => status["raw_return"].to_s.b)
    assert_kind_of Array, Crs.report_status

    indicators = captures.find { |c| c["rpc"] == RPCS[:indicators] }
    twin(RPCS[:indicators] => indicators["raw_return"].to_s.b)
    rows = Crs.indicators
    refute_empty rows, "the build lists its National GPRA measures"
    assert rows.all? { |r| r[:ien].is_a?(Integer) && !r[:name].to_s.empty? }, rows.first(3).inspect
  end
end
