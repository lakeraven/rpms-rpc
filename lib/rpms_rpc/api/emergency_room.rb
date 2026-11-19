# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "../shape"
require_relative "ddr_fileman"

module RpmsRpc
  # Reads of the ER Visit System (AMER 3.0). AMER registers no RPC of its own
  # and its screens are roll-and-scroll, so the record is read through the
  # generic FileMan RPCs (DDR GETS ENTRY DATA) over its own file:
  #
  #   #9009080 ER VISIT (^AMERVSIT): one completed ER visit. Fields read:
  #     .01 ADMISSION TIMESTAMP, .02 PATIENT, .03 VISIT (the PCC visit, #9000010),
  #     .05 VISIT TYPE, .06 ED PROVIDER, .07 TRIAGE NURSE, .24 EMERGENCY SEVERITY
  #     INDEX, .25 MODE OF TRANSPORT, 1 PRESENTING COMPLAINT, 6.1 DISPOSITION,
  #     6.2 DEPARTURE TIME, 6.6 TRANSFER TO (NEW), 12.2 TRIAGE NURSE TIME.
  #     Visit type, mode, and disposition point to ER OPTIONS (#9009083).
  #
  # BEDD (the ED Dashboard) is not a read path: it registers no RPC, its value
  # is IRIS CSP pages, and its data lives in IRIS class globals (^BEDD.EDVISITD)
  # that a YottaDB build cannot hold (openrpms#687, openrpms#1254).
  module EmergencyRoom
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"
    VISIT_FILE = "9009080"
    VISIT_FIELDS = ".01;.02;.03;.05;.06;.07;.24;.25;1;6.1;6.2;6.6;12.2"
    POSITIVE_IEN = /\A[1-9]\d*\z/

    # One ER visit of a patient, read back from #9009080:
    #   { ien:, dfn:, arrived_at:, pcc_visit_ien:, visit_type:, mode_of_transport:,
    #     presenting_complaint:, esi:, ed_provider:, triage_nurse:, triage_nurse_at:,
    #     disposition:, departed_at:, transfer_to: }
    # A pointer is { ien:, name: } or nil when blank; a time is a Time or nil;
    # esi is an Integer 1-5 or nil.
    #
    # nil when the build has no such visit (GETS^DIQ answers "[ERROR]") or the
    # visit belongs to another patient. Raises ArgumentError for an id that is
    # not a positive integer, and Client::RpcError when the read gives no reply
    # or a reply that is not GETS^DIQ's grammar: an error text is never data.
    def visit(dfn:, visit_ien:)
      patient = positive_id(dfn, "dfn")
      ien = positive_id(visit_ien, "visit_ien")

      read = ContextScope.scoped(RpmsRpc.client, CONTEXT) do
        DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{ien},", fields: VISIT_FIELDS, flags: "IE")
      end
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for ##{VISIT_FILE}" if read.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA gave a malformed reply for ##{VISIT_FILE}" if read[:malformed] || read[:stray]

      # "[ERROR]" (no such entry) carries no fields, so it fails this check too.
      fields = read[:fields]
      return nil unless internal(fields, ".02") == patient

      {
        ien: ien.to_i,
        dfn: patient.to_i,
        arrived_at: time(fields, ".01"),
        pcc_visit_ien: integer(fields, ".03"),
        visit_type: pointer(fields, ".05"),
        mode_of_transport: pointer(fields, ".25"),
        presenting_complaint: text(fields, "1"),
        esi: integer(fields, ".24"),
        ed_provider: pointer(fields, ".06"),
        triage_nurse: pointer(fields, ".07"),
        triage_nurse_at: time(fields, "12.2"),
        disposition: pointer(fields, "6.1"),
        departed_at: time(fields, "6.2"),
        transfer_to: pointer(fields, "6.6")
      }
    end
    shape :visit, resource: "emergency-rooms", verb: "GET", path: "/patients/{dfn}/emergency-rooms/visits/{visit_ien}"

    private

    def positive_id(value, name)
      id = value.to_s
      raise ArgumentError, "#{name} must be a positive integer" unless id.match?(POSITIVE_IEN)

      id
    end

    def internal(fields, field) = fields.dig(field, :internal).to_s

    def text(fields, field)
      value = internal(fields, field)
      value.empty? ? nil : value
    end

    def integer(fields, field) = text(fields, field)&.to_i

    def pointer(fields, field)
      ien = integer(fields, field)
      ien && { ien: ien, name: fields.dig(field, :external).to_s }
    end

    def time(fields, field)
      value = text(fields, field)
      value && FilemanDateParser.parse_datetime(value)
    end
  end
end
