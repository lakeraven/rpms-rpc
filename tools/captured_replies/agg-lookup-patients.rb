# frozen_string_literal: true

require "rpms_rpc/api/agg"

# AGG LOOKUP PATIENTS over CIA, with the inputs of the BMX frames in
# tools/captured_frames/agg-lookup-patients.rb (rpms-rpc#609). Over CIA the
# lookup that faults inside FND answers the same bytes as the genuine
# no-match: ERR^AGGPTLKP writes the $C(31) DONE writes (AGGPTLKP.m:73, :170)
# and its only signal, BMXSEC, reaches a BMX client alone.
pairs = lambda do |extra = {}|
  RpmsRpc::Agg.encode_parms({ "AGGPTLNM" => "ZZNOSUCHQX", "AGGPTFNM" => "NOBODY", "AGGPTMNM" => "",
                              "AGGPTSFX" => "", "AGGPTDOB" => "02/03/1901" }.merge(extra))
end
CAPTURE = {
  rpc: "AGG LOOKUP PATIENTS", entry_point: "FND^AGGPTLKP",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!", context: "AGGRPC",
  note: "Reads only. The fault pair makes S @NAME=VALUE (AGGPTLKP.m:39) fault inside FND; ^%ZTER records it.",
  calls: [
    { name: "no_match", inputs: [ pairs.call, "", "1", "1" ], about: "a name and DOB no patient has" },
    { name: "fault", inputs: [ pairs.call("1BAD" => "X"), "", "1", "1" ],
      about: "the no-match pairs plus 1BAD=X: an M error inside FND, answered like a no-match" }
  ]
}.freeze
