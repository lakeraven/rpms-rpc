# frozen_string_literal: true

require "rpms_rpc/api/agg_lookups"

# The registration GUI's lookups, as RpmsRpc::Agg sends them under AGGRPC,
# recorded as flows as the front desk clerk test role on the demo image.
# Reads only.
A = RpmsRpc::Agg
CAPTURE = {
  rpc: "AGG VERSION INFO", entry_point: "EN^AGGVER",
  signed_on_as: "PROFILE,REG (PREG123, the front desk clerk test role's published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Reads only.",
  flows: {
    "version_info" => { about: "Agg.version_info(AG)", run: -> { A.version_info } },
    "division_parameters" => { about: "Agg.division_parameters", run: -> { A.division_parameters } },
    "reports" => { about: "Agg.reports", run: -> { A.reports } },
    "table_entries" => { about: "Agg.table_entries(9000001)", run: -> { A.table_entries(9_000_001) } },
    "window_definition" => { about: "Agg.window_definition(Mini Registration)", run: -> { A.window_definition("Mini Registration") } },
    "window_definition_none" => { about: "Agg.window_definition(NO SUCH WINDOW)", run: -> { A.window_definition("NO SUCH WINDOW") } },
    "key_held" => { about: "Agg.key_held(AGZMENU): the clerk's key", run: -> { A.key_held("AGZMENU") } },
    "key_not_held" => { about: "Agg.key_held(AGZMGR): the supervisor's key", run: -> { A.key_held("AGZMGR") } }
  }
}.freeze
