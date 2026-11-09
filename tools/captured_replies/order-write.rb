# frozen_string_literal: true

require "rpms_rpc/api/order"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/valid_signature"

# The order conversations RpmsRpc::Order has, as PROFILE,MD on seed patient
# DFN 990034, on a throwaway container: an order saved unreleased (ORWDX SAVE),
# order checks (ORWDXC ACCEPT), and two saved orders signed and released or
# refused (ORWU VALIDSIG, ORWDX SEND). The dialog is OR GXTEXT WORD PROCESSING
# ORDER, as the order write live spec uses. rpms-rpc#620.
ORDER_DFN = "990034"
DUZ = "206"
DIALOG = "OR GXTEXT WORD PROCESSING ORDER"
TEXT = "rpms-rpc captured order"

# Dialog prompts, display group and location, read as the live spec reads them.
def order_context(client)
  lines = Array(client.call_rpc("ORWDX DLGDEF", DIALOG)).flat_map { |c| c.to_s.split(/\r\n|\r|\n/) }
  prompts = lines.to_h { |l| name, rest = l.split("^", 2); [ name.to_s.upcase, rest.to_s.split("^").first.to_i ] }
  dialog = RpmsRpc::DdrFileman.lister(file: "101.41", fields: ".01", flags: "IP")[:entries].find { |r| r[:pieces].first == DIALOG }
  group = RpmsRpc::DdrFileman.gets_entry(file: "101.41", iens: "#{dialog[:ien]},", fields: "5", flags: "IE")[:fields].dig("5", :internal)
  { comment: prompts.fetch("COMMENT"), start: prompts.fetch("START"), stop: prompts.fetch("STOP"),
    display_group: group.to_s, location: "7" }
end

def responses(ctx, text)
  { [ ctx[:start], 1 ] => "NOW", [ ctx[:stop], 1 ] => "", [ ctx[:comment], 1 ] => %(ORDIALOG("WP",#{ctx[:comment]},1)),
    [ "WP", ctx[:comment], 1, 1, 0 ] => text }
end

def save(ctx, text)
  RpmsRpc::Order.save(ORDER_DFN, DUZ, ctx[:location], DIALOG, responses(ctx, text), display_group: ctx[:display_group])
end

CTX = {} # filled by setup, read by the flows

CAPTURE = {
  rpc: "ORWDX SAVE", entry_point: "SAVE^ORWDX",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    CTX.merge!(order_context(client))
    signed = save(CTX, "#{TEXT} to sign")
    refused = save(CTX, "#{TEXT} with a wrong code")
    raise "setup saved no order: #{signed.inspect} #{refused.inspect}" unless signed[:success] && refused[:success]

    RpmsRpc.reset!
    CTX.merge!(signed: signed[:order_id], refused: refused[:order_id])
  },
  note: "Seed patient DFN 990034 (synthetic data), hospital location 7. Setup saves two orders (unrecorded) for " \
        "the sign captures to act on; their ids are in those captures' inputs. The signature code is the " \
        "persona's demo code that SEEDPERS files (published like the sign-on pairs); its ciphertext is withheld, " \
        "because the cipher picks a random row pair. The build answers ORWDXC ACCEPT with no rows for every " \
        "orderable tried (rpms-rpc#383).",
  calls: [
    { name: "validsig", rpc: "ORWU VALIDSIG", inputs: [ "<the persona's demo signature code, encrypted; withheld>" ],
      wire_inputs: ->(_client) { [ RpmsRpc::ValidSignature.encrypt("123456") ] }, about: "the persona's own code" },
    { name: "send", rpc: "ORWDX SEND",
      inputs: ->(s) { [ ORDER_DFN, DUZ, "7", "<the same code, encrypted; withheld>", [ "#{s[:signed]}^1^1^E" ] ] },
      wire_inputs: ->(_client, s) { [ ORDER_DFN, DUZ, "7", RpmsRpc::ValidSignature.encrypt("123456"), [ "#{s[:signed]}^1^1^E" ] ] },
      about: "sign and release the first saved order" },
    { name: "send_again", rpc: "ORWDX SEND",
      inputs: ->(s) { [ ORDER_DFN, DUZ, "7", "<the same code, encrypted; withheld>", [ "#{s[:signed]}^1^1^E" ] ] },
      wire_inputs: ->(_client, s) { [ ORDER_DFN, DUZ, "7", RpmsRpc::ValidSignature.encrypt("123456"), [ "#{s[:signed]}^1^1^E" ] ] },
      about: "the same order again, already released" },
    { name: "validsig_wrong", rpc: "ORWU VALIDSIG", inputs: [ "<a code the persona does not hold, encrypted; withheld>" ],
      wire_inputs: ->(_client) { [ RpmsRpc::ValidSignature.encrypt("999999") ] }, about: "a code that is not the persona's" },
    { name: "accept_unknown_rpc", rpc: "ORWDXC ACCEPTX", inputs: [ ORDER_DFN ], expect_error: true,
      about: "an RPC the broker does not serve: its refusal" }
  ],
  flows: {
    "save" => { about: "Order.save: a word-processing order, left unreleased",
                run: -> { save(CTX, TEXT) } },
    "check_drug" => { about: "Order.check: the build's one PS orderable (ASPIRIN, #101.43 1521) for DFN 4",
                      run: lambda {
                        RpmsRpc::Order.check("4", filler_id: "PSO", location: "7",
                                                  items: [ { orderable_item: "1521", package: "PS", package_info: "1" } ])
                      } },
    "check_lab" => { about: "Order.check: a lab orderable (#101.43 450) for DFN 990034",
                     run: lambda {
                       RpmsRpc::Order.check(ORDER_DFN, filler_id: "LR", location: "7",
                                                       items: [ { orderable_item: "450", package: "LR", package_info: "" } ])
                     } }
  }
}.freeze
