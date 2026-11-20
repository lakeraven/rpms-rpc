# frozen_string_literal: true

require "rpms_rpc/api/bgu"

# RpmsRpc::Bgu.send_mailman_message on the build as PROVIDER,TEST
# (rpms-rpc#619). It sends MailMan messages, so it runs on a throwaway
# container only. EN^BGUMAIL answers 1/OK on every path, so both flows are
# what any call gets back: one to the build's BILLING mail group, one to a
# group that does not exist.
CAPTURE = {
  rpc: "BGU MAILMAN MESSAGE", entry_point: "EN^BGUMAIL",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container: each flow sends a MailMan message of synthetic text.",
  calls: [],
  flows: {
    "sent" => { about: "a two-line message to the BILLING mail group",
                run: lambda {
                  RpmsRpc::Bgu.send_mailman_message(subject: "Synthetic subject", group: "BILLING",
                                                    body: "Synthetic line one\nSynthetic line two")
                } },
    "group_not_on_file" => { about: "a message to NOSUCH GROUP, a mail group the build does not have",
                             run: lambda {
                               RpmsRpc::Bgu.send_mailman_message(subject: "Synthetic subject", group: "NOSUCH GROUP",
                                                                 body: "Synthetic line one")
                             } }
  }
}.freeze
