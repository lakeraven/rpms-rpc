# frozen_string_literal: true

require "rpms_rpc/api/agg"

# RpmsRpc::Agg.update_legal_names on the build as PROFILE,REG (rpms-rpc#619):
# the #9000033 ownership read (DDR GETS ENTRY DATA) and LEGL^AGGPTNAM. The gem
# refuses a blank-RIEN add, so the "rows" flow files one PATIENT NAME CHANGES
# row each for DFN 990031 and DFN 990032 through the stock RPC itself. Every
# flow writes, so this runs on a throwaway container only; the RIENs are the
# ones that container assigned.
Agg = RpmsRpc::Agg
LEGL = "AGG UPDATE LEGAL NAMES"
$legal_riens = {} # rubocop:disable Style/GlobalVars

# Each row gets its own date, so each add files a row of its own.
def add_row(dfn, name, date)
  RpmsRpc.client.create_context("AGGRPC")
  reply = RpmsRpc.client.call_rpc_global_array(LEGL, dfn, "A", "", "AGGLNDTC=#{date}\x1cAGGLNMC=#{name}").to_s
  $legal_riens[dfn] = reply[/\x1e1\^\^(\d+)\x1e/, 1] || raise("LEGL did not add a row: #{reply.inspect}") # rubocop:disable Style/GlobalVars
end

def rien(dfn) = $legal_riens.fetch(dfn) # rubocop:disable Style/GlobalVars

CAPTURE = {
  rpc: LEGL, entry_point: "LEGL^AGGPTNAM",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Run on a throwaway container: the rows flow adds two #9000033 rows through the stock RPC, and the " \
        "update flows edit and delete them.",
  calls: [
    { name: "legl_row_not_on_file", context: "AGGRPC", global_array: true, inputs: [ "990031", "", "999999", "AGGLNMC=SYNTH,LEGAL" ],
      about: "LEGL editing RIEN 999999, which no row has: the reply a row deleted after the read would get" }
  ],
  flows: {
    "rows" => { about: "LEGL adds one row for DFN 990031 and one for DFN 990032 (the setup)",
                run: -> { add_row("990031", "SYNTH,LEGAL", "10/01/2026") && add_row("990032", "SYNTH,OTHER", "10/02/2026") } },
    "edit" => { about: "update_legal_names: proc \"\" edits DFN 990031's row's name",
                run: -> { Agg.update_legal_names(dfn: 990_031, proc: "", rien: rien("990031"), params: { "AGGLNMC" => "SYNTH,LEGALTWO" }) } },
    "edit_a" => { about: "update_legal_names: proc A edits the same row's date",
                  run: -> { Agg.update_legal_names(dfn: 990_031, proc: "A", rien: rien("990031"), params: { "AGGLNDTC" => "11/05/2026" }) } },
    "not_for_dfn" => { about: "update_legal_names for DFN 990031 naming DFN 990032's row",
                       run: -> { Agg.update_legal_names(dfn: 990_031, proc: "D", rien: rien("990032"), params: {}) } },
    "no_row" => { about: "update_legal_names naming RIEN 999999, which no row has",
                  run: -> { Agg.update_legal_names(dfn: 990_031, proc: "D", rien: 999_999, params: {}) } },
    "delete" => { about: "update_legal_names: proc D deletes DFN 990031's row",
                  run: -> { Agg.update_legal_names(dfn: 990_031, proc: "D", rien: rien("990031"), params: {}) } }
  }
}.freeze
