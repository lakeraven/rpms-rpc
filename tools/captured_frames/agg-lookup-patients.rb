# frozen_string_literal: true

require "rpms_rpc/api/agg"

# AGG LOOKUP PATIENTS over BMX, with the inputs Agg.registration_candidates
# sends for Registration's duplicate check (rpms-rpc#609): the name pieces and
# DOB as $C(28)-separated pairs, all divisions, inactive charts included.
# "fault" adds a pair whose name is not a valid M local, so S @NAME=VALUE
# (AGGPTLKP.m:39) faults inside FND and ERR^AGGPTLKP runs: over BMX the
# error reaches the client in the security packet (BMXSEC, AGGPTLKP.m:169).
pairs = lambda do |extra = {}|
  RpmsRpc::Agg.encode_parms({ "AGGPTLNM" => "ZZNOSUCHQX", "AGGPTFNM" => "NOBODY", "AGGPTMNM" => "",
                              "AGGPTSFX" => "", "AGGPTDOB" => "02/03/1901" }.merge(extra))
end
CAPTURE = {
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!", context: "AGGRPC",
  note: "Reads only. The fault pair is the one way to make FND fault without a broken build.",
  calls: [
    { name: "no_match", rpc: "AGG LOOKUP PATIENTS", inputs: [ pairs.call, "", "1", "1" ],
      about: "a name and DOB no patient has: the typed header alone" },
    { name: "match", rpc: "AGG LOOKUP PATIENTS",
      inputs: [ RpmsRpc::Agg.encode_parms({ "AGGPTLNM" => "USER", "AGGPTFNM" => "TEST", "AGGPTMNM" => "",
                                            "AGGPTSFX" => "", "AGGPTDOB" => "05/05/1985" }), "", "1", "1" ],
      about: "demo patient 2's name and DOB (USER,TEST, 05/05/1985): one candidate" },
    { name: "fault", rpc: "AGG LOOKUP PATIENTS", inputs: [ pairs.call("1BAD" => "X"), "", "1", "1" ],
      about: "the no-match pairs plus 1BAD=X, which faults S @NAME=VALUE inside FND" }
  ]
}.freeze
