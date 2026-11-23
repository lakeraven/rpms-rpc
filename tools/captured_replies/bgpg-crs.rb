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
# SITE PARAMETERS). The image ships neither.
#
# Both queue RPCs are recorded as the build answered them: refused, because
# CRS on this build cannot file the report entry (REPORT^BGPXUTL;
# openrpms#1305). The patient-list refusal is the bare row 0 (NPL^BGPXGR
# answers +$G(BGPERR)); the National GPRA refusal keeps its reason. With
# nothing queued, the operator has no reports, and report 1 has no output.
CAPTURE = {
  rpc: "BGPG 25 GET SITE PARAMETERS", entry_point: "SP^BGPXGU",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM; DUZ 4), the one account that can run BGPGRPC",
  access: "SYS123", verify: "RPMS.000", context: "BGPGRPC",
  note: "Run on a throwaway container given a synthetic community taxonomy (3471) and the division's CRS site " \
        "parameters through stock RPCs. Both queue RPCs answered a refusal on this build (openrpms#1305).",
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
    "queue_national_gpra_refused" => {
      about: "the National GPRA report for taxonomy 3471, refused: CRS could not create the report entry (openrpms#1305)",
      run: lambda do
        RpmsRpc::Crs.queue_national_gpra(community_taxonomy: 3471, name: "SYNTH NTL CAPTURE")
      rescue RpmsRpc::Crs::QueueRefusedError
        nil
      end
    },
    "queue_patient_lists_refused" => {
      about: "the Diabetes DX Ever list (measure 1, list 1) for the year ending 2026-11-23, AI/AN, all patients, " \
             "refused: NPL answers the bare number 0 (openrpms#1305)",
      run: lambda do
        RpmsRpc::Crs.queue_patient_lists(community_taxonomy: 3471, name: "SYNTH NPL CAPTURE", lists: { 1 => [ 1 ] },
                                         period: { ends: Date.new(2026, 11, 23) }, baseline_year: 2010, population: :aian)
      rescue RpmsRpc::Crs::QueueRefusedError
        nil
      end
    },
    "report_status_none" => { about: "the operator's CRS reports: none (nothing could be queued)",
                              run: -> { RpmsRpc::Crs.report_status } },
    "report_output_none" => { about: "the output of report 1, which is not on file: the header alone",
                              run: -> { RpmsRpc::Crs.report_output(1) } }
  }
}.freeze
