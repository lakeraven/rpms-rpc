# frozen_string_literal: true

require "date"
require "rpms_rpc/api/crs"

# RpmsRpc::Crs on the build as the operator (rpms-rpc#920). The BGPG 25 RPCs
# are registered under BGPGRPC only, and no published demo persona has that
# option on its menu tree; the operator holds XUPROGMODE, which the broker's
# context check bypasses.
#
# The container had been given, through stock RPCs only, a community taxonomy
# (BQI UPDATE COMM TAXONOMY: ien 3471, SYNTH CRS COMMUNITIES, one community)
# and the division's BGP SITE PARAMETERS entry pointing at it (BGPG 25 SAVE
# SITE PARAMETERS, with .04 INCLUDE DATA IN WEB EISS? = N; the RPC files that
# Y/N field unvalidated, and any other value makes every report request
# refuse). The image ships neither. Synthetic AI/AN diabetic patients had been
# registered in the taxonomy's community, and National GPRA patient lists run
# to completion before the capture.
#
# Both queue RPCs are recorded filing a report, and refusing one for a
# taxonomy ien that is not on file: the patient-list refusal is the bare row 0
# (NPL^BGPXGR answers +$G(BGPERR)), the National GPRA refusal keeps its
# reason. The completed-list flow reads the operator's reports and the output
# of the first completed patient-list report. Of the two this run queued, the
# one whose TaskMan job was running reads ERRORED (JOBPAR^%ZOSV does not
# recognise a yottadb process, openrpms#1305) and the one not yet started
# reads RUNNING.
CAPTURE = {
  rpc: "BGPG 25 GET SITE PARAMETERS", entry_point: "SP^BGPXGU",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM; DUZ 4), the one account that can run BGPGRPC",
  access: "SYS123", verify: "RPMS.000", context: "BGPGRPC",
  note: "Run on a throwaway container given a synthetic community taxonomy (3471), the division's CRS site " \
        "parameters (EISS N) and synthetic diabetic patients through stock RPCs, after a patient-list report completed.",
  calls: [
    { name: "taxonomy_check_report_merror", rpc: "BGPG 25 GET TAXONOMIES", inputs: [ "BGPXXTCN|" ], global_array: true,
      about: "TAXCHK^BGPXGU prints through a device the CIA session has not opened: the M error is trapped " \
             "to MERR^BGPXGU and answered as the T00250MError table" }
  ],
  flows: {
    "site_parameters" => { about: "the signed-on division's CRS site parameters: location, home location, " \
                                  "community taxonomy and EISS",
                           run: -> { RpmsRpc::Crs.site_parameters } },
    "community_taxonomy_clean" => { about: "taxonomy 3471, whose one community is in the standard table: no warnings",
                                    run: -> { RpmsRpc::Crs.community_taxonomy(3471) } },
    "taxonomies" => { about: "the CRS (BGP) package taxonomies with their state, kind and file",
                      run: -> { RpmsRpc::Crs.taxonomies } },
    "indicators" => { about: "the National GPRA measures (report type 1)",
                      run: -> { RpmsRpc::Crs.indicators } },
    "queue_national_gpra" => {
      about: "the National GPRA report for taxonomy 3471: filed, answering the report ien",
      run: -> { RpmsRpc::Crs.queue_national_gpra(community_taxonomy: 3471, name: "SYNTH NTL CAPTURE") }
    },
    "queue_national_gpra_unknown_taxonomy" => {
      about: "the National GPRA report for a taxonomy ien not on file: refused with CRS's reason",
      run: lambda do
        RpmsRpc::Crs.queue_national_gpra(community_taxonomy: 999_999, name: "SYNTH NTL REFUSED")
      rescue RpmsRpc::Crs::QueueRefusedError
        nil
      end
    },
    "queue_patient_lists" => {
      about: "the Diabetes DX Ever list (measure 1, list 1) for the year ending 2026-11-23, AI/AN, all patients: " \
             "filed, answering the report ien",
      run: lambda {
        RpmsRpc::Crs.queue_patient_lists(community_taxonomy: 3471, name: "SYNTH NPL CAPTURE", lists: { 1 => [ 1 ] },
                                         period: { ends: Date.new(2026, 11, 23) }, baseline_year: 2010, population: :aian)
      }
    },
    "queue_patient_lists_unknown_taxonomy" => {
      about: "the same lists for a taxonomy ien not on file: refused, and NPL answers the bare number 0",
      run: lambda do
        RpmsRpc::Crs.queue_patient_lists(community_taxonomy: 999_999, name: "SYNTH NPL REFUSED", lists: { 1 => [ 1 ] },
                                         period: { ends: Date.new(2026, 11, 23) }, baseline_year: 2010, population: :aian)
      rescue RpmsRpc::Crs::QueueRefusedError
        nil
      end
    },
    "completed_patient_list" => {
      about: "the operator's CRS reports (of the two just queued, the one whose job is running reads ERRORED, " \
             "because JOBPAR^%ZOSV does not recognise a yottadb process (openrpms#1305), and the other RUNNING), " \
             "then the output of the first completed patient-list report: synthetic patients under Diabetes " \
             "Prevalence",
      run: lambda {
        done = RpmsRpc::Crs.report_status.find { |r| r[:status] == "COMPLETED" && r[:type] == "CRS 25 NPL" }
        abort "no completed CRS 25 NPL report on the container; run one before capturing" if done.nil?
        RpmsRpc::Crs.report_output(done[:ien])
      }
    },
    "report_output_not_on_file" => { about: "the output of a report ien that is not on file: the header alone",
                                     run: -> { RpmsRpc::Crs.report_output(999_999) } }
  }
}.freeze
