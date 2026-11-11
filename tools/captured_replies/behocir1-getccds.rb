# frozen_string_literal: true

require "rpms_rpc/api/phr"

# BEHOCIR1 GETCCDS, as RpmsRpc::Phr.for_patient sends it (rpms-rpc#698):
# GETCCDS(DATA,DFN,STRTDT,ENDDT)^BEHOCIR1, which calls GETIMGS^MAGSIXG1.
# VistA Imaging's MAGSIXG1 is not in the FOIA release, so the build answers
# an M error for any frame; the one-parameter "DFN^MM/DD/YYYY^MM/DD/YYYY"
# frame the gem used to send is kept beside the three-parameter one.
CAPTURE = {
  rpc: "BEHOCIR1 GETCCDS", entry_point: "GETCCDS^BEHOCIR1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Seed patient DFN 4 (synthetic data). The build has no IMAGE (#2005) entries.",
  calls: [
    { name: "one_parameter", inputs: [ "4^01/01/2000^12/31/2026" ], expect_error: true,
      about: "the frame for_patient used to send: one caret-joined parameter" }
  ],
  flows: {
    "for_patient" => {
      about: "for_patient for DFN 4, 01/01/2000 to 12/31/2026: three parameters; MAGSIXG1 is absent",
      run: lambda do
        RpmsRpc::Phr.for_patient(4, start_date: Date.new(2000, 1, 1), end_date: Date.new(2026, 12, 31))
      rescue RpmsRpc::Client::RpcError => e
        e
      end
    }
  }
}.freeze
