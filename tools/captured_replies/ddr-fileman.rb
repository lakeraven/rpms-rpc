# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/cia_client"

# RpmsRpc::DdrFileman's calls on the build as PROVIDER,TEST (rpms-rpc#619):
# DDR FILER, LISTER, LOCK/UNLOCK NODE, GETS ENTRY DATA, VALIDATOR and KEY
# VALIDATOR, each as the gem sends it. The filer flows add PATIENT NAME CHANGES
# (#9000033) rows, so this runs on a throwaway container only; the IENs are
# the ones it assigned. The held-lock flow takes the node on a second session,
# signed on as PROFILE,MD, which the flow opens itself and does not record.
Ddr = RpmsRpc::DdrFileman
NODE = "^AUPNPAT(990031)"
CAPTURE = {
  rpc: "DDR LISTER", entry_point: "LISTC^DDR",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container: the filer flows add #9000033 rows for DFN 990031.",
  calls: [],
  flows: {
    "filer_add" => { about: "filer ADD: a #9000033 row for DFN 990031, dated 10/03/2026, its document a certificate of degree of Indian blood",
                     run: lambda {
                       Ddr.filer(mode: "ADD", rows: [ { file: "9000033", field: ".01", iens: "+1,", value: "10/03/2026" },
                                                      { file: "9000033", field: ".02", iens: "+1,", value: "`990031" },
                                                      { file: "9000033", field: ".04", iens: "+1,", value: "`12" } ])
                     } },
    "filer_bad_value" => { about: "filer ADD of a .01 alone (X): the build refuses the record",
                           run: -> { Ddr.filer(mode: "ADD", rows: [ { file: "9000033", field: ".01", iens: "+1,", value: "X" } ]) } },
    "lister_rows" => { about: "lister of NEW PERSON (#200) on B from PROFILE: the PROFILE users",
                       run: -> { Ddr.lister(file: "200", fields: "@;.01", flags: "IP", xref: "B", part: "PROFILE", max: "*") } },
    "lister_more" => { about: "the same list, two at a time",
                       run: -> { Ddr.lister(file: "200", fields: "@;.01", flags: "IP", xref: "B", part: "PROFILE", max: "2") } },
    "lister_empty" => { about: "the same list for a prefix no name has",
                        run: -> { Ddr.lister(file: "200", fields: "@;.01", flags: "IP", xref: "B", part: "ZZNOSUCH", max: "*") } },
    "lister_bad_file" => { about: "lister of file 99999999, which the build does not have",
                           run: -> { Ddr.lister(file: "99999999", fields: "@;.01", flags: "IP") } },
    "lock" => { about: "lock and unlock DFN 990031's IHS patient node",
                run: -> { Ddr.lock(node: NODE) && Ddr.unlock(node: NODE) } },
    "lock_held" => { about: "lock of a node another session holds",
                     run: lambda do
                       other =RpmsRpc::CiaClient.new(host: "127.0.0.1", port: Integer(ENV.fetch("BROKER_PORT", "9100")), timeout: 30)
                       other.connect
                       other.authenticate("PMD123", "PMD123!!")
                       other.call_rpc("DDR LOCK/UNLOCK NODE", Ddr.lock_param(node: NODE))
                       Ddr.lock(node: NODE, timeout: 1)
                     ensure
                       other&.disconnect
                     end },
    "gets" => { about: "gets_entry of DFN 990031's name and sex, internal and external",
                run: -> { Ddr.gets_entry(file: "2", iens: "990031,", fields: ".01;.02", flags: "IE") } },
    "gets_not_on_file" => { about: "gets_entry of a patient IEN no patient has",
                            run: -> { Ddr.gets_entry(file: "2", iens: "999999999,", fields: ".01") } },
    "validate_ok" => { about: "validate_field: 10/03/2026 as a #9000033 .01",
                       run: -> { Ddr.validate_field(file: "9000033", iens: "+1,", field: ".01", value: "10/03/2026") } },
    "validate_bad" => { about: "validate_field: X as a #9000033 .01",
                        run: -> { Ddr.validate_field(file: "9000033", iens: "+1,", field: ".01", value: "X") } },
    "validate_key" => { about: "validate_key of a NEW PERSON name",
                        run: -> { Ddr.validate_key(values: [ { file: "200", iens: "+1,", field: ".01", value: "ZZTEST" } ]) } }
  }
}.freeze
