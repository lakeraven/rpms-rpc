# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the IHS **AG** package's GUI registration RPCs (the AGG*
  # namespace, context option AGGRPC). These encapsulate the AG registration
  # business logic — demographics filing into PATIENT (#2) and IHS PATIENT
  # (#9000001), the HEALTH RECORD 41-multiple, HL7/MPI staging into
  # ^XTMP("AGHL7"), the ^AGPATCH register stamp, and the completeness
  # edit-check battery — so a client that DELEGATES to them inherits the
  # capsule instead of reimplementing it (see RpmsRpc::Registration).
  #
  # AG is an RPMS-only package: civilian/stock VistA has no AG, so callers
  # gate on Agg.available? and fall back to the VOA + DDR composition.
  #
  # Context: these RPCs are registered under the AGGRPC option (file 19 IEN
  # 13112, "Patient Registration GUI"). Establish it with
  # `client.create_context("AGGRPC")` before delegating — RPC registration is
  # OPTION-scoped.
  #
  # Session hygiene (probe caveat, rpms-rpc#214): AG routines leak un-NEWed
  # locals (BN/SECFLD/BMXSEC/RESULT in ADD^AGGPTADD) into a long-lived CIA
  # session job — a live multi-RPC session was observed to kill AGG UPDATE
  # PATIENT with a zero-byte reply and nothing filed, while the identical
  # call in a fresh session succeeded. Prefer SHORT broker sessions for AGG
  # writes (a fresh sign-on per registration workflow); do not stack many AGG
  # writes on one long-lived session. (Server env note for operators: the
  # export hook EDIT^AGGEXPRT requires DUZ("AG")="I", which a proper Kernel
  # sign-on sets.)
  #
  # ## Wire contract (capture-verified live on bcer-9.0-ydb, rpms-rpc#214)
  #
  # Request  — P1 = window name (file 9009068.3), P2 = DFN ("" for a new
  #            patient), P3 = the PARMS string: $C(28)-delimited NAME=VALUE
  #            pairs (AGGPTLNM/AGGPTFNM/AGGPTMNM/AGGPTSFX/AGGPTDOB/AGGPTSEX/
  #            AGGPTSSN/AGGNOSSN/AGGPTMAR/AGGPTHME/AGGPTHRN/DFN).
  # Response — a GLOBAL ARRAY (broker return type 4): a typed header row
  #            "I00010RESULT^T00080MESSAGE^I00010DFN" (each piece is
  #            <type><5-digit-width><NAME>), then $C(30)-separated data
  #            records, ending $C(31). "1^^DFN" = success, "-1^message" =
  #            rejected. Read to the $C(31) sentinel — see
  #            CiaClient#call_rpc_global_array (RS == the CIA EOD, so the
  #            default read truncates at the header).
  #
  #   RPC                        routine^tag       source
  #   AGG ADD NEW PATIENT        ADD^AGGPTADD      #214 live probe
  #   AGG UPDATE PATIENT         UPD^AGGPTUPD      #214 live probe
  #   AGG PATIENT EDIT CHECK     CHK^AGGEDCHK      #214 live probe
  #   (presence gate)            CANRUN^CIANBACT   #214 live probe
  module Agg
    extend self

    # AGG* RPC names (registered in #8994 under the AGGRPC option).
    ADD_RPC = "AGG ADD NEW PATIENT"           # ADD^AGGPTADD, return type GLOBAL ARRAY
    UPDATE_RPC = "AGG UPDATE PATIENT"         # UPD^AGGPTUPD
    EDIT_CHECK_RPC = "AGG PATIENT EDIT CHECK" # CHK^AGGEDCHK
    CANRUN_RPC = "CIANBRPC CANRUN"            # CANRUN^CIANBACT (broker gate)

    # Registration window definitions (file 9009068.3). "Mini Registration"
    # (IEN 29) is the minimal demographics set; "New Patient" (IEN 28) is a
    # 28-param superset.
    DEFAULT_WINDOW = "Mini Registration"

    # PARMS framing bytes.
    PARM_DELIM = "\x1c" # $C(28) — NAME=VALUE separator in the PARMS string
    RECORD_SEP = "\x1e" # $C(30) — record separator in the reply (== CIA EOD)
    ARRAY_END  = "\x1f" # $C(31) — end-of-array sentinel
    ACK = "\x00"        # broker ack byte following the 1-byte sequence echo

    # Is the AGG registration suite installed and runnable for this client?
    #
    # Real registry evidence (rpms-rpc#209, #214): CANRUN^CIANBACT checks
    # "AGG ADD NEW PATIENT" against the current context option's RPC
    # multiple and answers 1/0 WITHOUT executing the (write) RPC — so this
    # never files anything, unlike an execution probe. Caveat: CANRUN has an
    # unconditional bypass for holders of XUPROGMODE (returns 1 regardless),
    # so a programmer session always sees AGG as available.
    def available?(client = RpmsRpc.client)
      raw = if client.respond_to?(:call_rpc_raw)
        client.call_rpc_raw(CANRUN_RPC, ADD_RPC)
      else
        client.call_rpc(CANRUN_RPC, ADD_RPC)
      end
      body = raw.to_s.b
      body = body.split(ACK, 2).last.to_s if body.include?(ACK)
      body.split(/[\r\n#{RECORD_SEP}]/).first.to_s.strip == "1"
    rescue RpmsRpc::Client::RpcError
      false
    end

    # ADD^AGGPTADD — create a patient from a demographics PARMS hash.
    # Returns { success: true, dfn:, message: } on "1^^DFN",
    # { success: false, error: :agg_rejected, message: } on "-1^message",
    # or nil when the broker gives no response.
    def add_patient(params:, window: DEFAULT_WINDOW, dfn: "", client: RpmsRpc.client)
      interpret_write(call_array(client, ADD_RPC, window, dfn.to_s, encode_parms(params)))
    end

    # UPD^AGGPTUPD — edit an existing patient (DFN required). Same PARMS
    # convention and reply shape as ADD (header RESULT^ERROR^OTHER_PARMS).
    def update_patient(dfn:, params:, window: DEFAULT_WINDOW, client: RpmsRpc.client)
      interpret_write(call_array(client, UPDATE_RPC, window, dfn.to_s, encode_parms(params)))
    end

    # CHK^AGGEDCHK — the completeness edit-check battery for a patient.
    # Exposed for UX-grade validation feedback; NOT an integrity gate.
    # Returns { checks: [{ hide_error_num:, msg:, type: ("MANDATORY" /
    # "WARNING"), ... }] } or nil (no response).
    def edit_check(dfn:, client: RpmsRpc.client)
      reply = parse_reply(call_array(client, EDIT_CHECK_RPC, dfn.to_s))
      return nil if reply.nil?

      { checks: reply[:records] }
    end

    # Encode a NAME=VALUE PARMS hash as the $C(28)-delimited string P3.
    # nil values are dropped; everything is sent as-is (FileMan-external —
    # AGGPTSEX is the coded set value "MALE"/"FEMALE", dates MM/DD/YYYY).
    def encode_parms(params)
      params.reject { |_, v| v.nil? }
            .map { |name, value| "#{name}=#{value}" }
            .join(PARM_DELIM)
    end

    # Parse a raw GLOBAL ARRAY reply into { header: [names], records:
    # [{name => value}] }. Strips the leading sequence echo + \x00 ack, cuts
    # at the $C(31) end sentinel, splits records on $C(30), and maps each
    # record's "^"-pieces onto the typed-header field names. nil on an empty
    # reply.
    def parse_reply(raw)
      return nil if raw.nil?

      body = raw.to_s.b
      body = body.split(ACK, 2).last.to_s if body.include?(ACK)
      body = body.split(ARRAY_END, 2).first.to_s
      return nil if body.empty?

      rows = body.split(RECORD_SEP)
      return nil if rows.empty?

      names = parse_header(rows.shift)
      records = rows.reject(&:empty?).map do |row|
        pieces = row.split("^", -1)
        names.each_with_index.to_h { |name, i| [ name, pieces[i] ] }
      end
      { header: names, records: records }
    end

    private

    # Route through the GLOBAL ARRAY read when the client supports it (live
    # CiaClient); fall back to plain call_rpc for a MockClient / non-CIA
    # client that returns the seeded reply directly.
    def call_array(client, rpc_name, *params)
      if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(rpc_name, *params)
      else
        client.call_rpc(rpc_name, *params)
      end
    end

    # Header pieces are typed field descriptors "<type><5-digit width><NAME>"
    # (e.g. "I00010RESULT", "T00080MESSAGE"); strip the type+width prefix and
    # symbolize the NAME.
    def parse_header(header)
      header.to_s.split("^", -1).map do |piece|
        m = piece.match(/\A[A-Z]\d{5}(.*)\z/m)
        (m ? m[1] : piece).downcase.to_sym
      end
    end

    def interpret_write(reply)
      parsed = parse_reply(reply)
      return nil if parsed.nil?

      record = parsed[:records].first
      return { success: false, error: :agg_empty_reply, message: "AGG reply carried no data record" } if record.nil?

      message = record[:message] || record[:error] || ""
      if record[:result].to_s == "1"
        dfn = record[:dfn].to_s
        { success: true, dfn: dfn.empty? ? nil : dfn.to_i, message: message.to_s }
      else
        text = message.to_s.empty? ? record.values.compact.join("^") : message.to_s
        { success: false, error: :agg_rejected, message: text }
      end
    end
  end
end
