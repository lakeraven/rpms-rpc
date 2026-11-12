# frozen_string_literal: true

require_relative "../mappings"
require_relative "../client"
require_relative "../shape"

module RpmsRpc
  # Symbolic API for the IHS **AG** package's GUI registration RPCs (the AGG*
  # namespace, context option AGGRPC). These encapsulate the AG registration
  # business logic — demographics filing into PATIENT (#2) and IHS PATIENT
  # (#9000001), the HEALTH RECORD 41-multiple, HL7/MPI staging into
  # ^XTMP("AGHL7"), the ^AGPATCH register stamp, and the completeness
  # edit-check battery — so a client that DELEGATES to them inherits the
  # capsule instead of reimplementing it (see RpmsRpc::Registration).
  #
  # AG is an RPMS-only package, on every RPMS baseline (rpms-rpc#407).
  # RpmsRpc::Registration registers through it alone: the VOA + DDR
  # composition it once fell back to is served by no context on RPMS
  # (rpms-rpc#409).
  #
  # ## Context — this module binds it, callers do not (rpms-rpc#225)
  #
  # The AGG* RPCs are registered under the AGGRPC option and ONLY there:
  # `^DIC(19,13112,0)="AGGRPC^Patient Registration GUI^^B^…"` (TYPE "B", no
  # LOCK) with AGG ADD NEW PATIENT (8994 IEN 3374) in its RPC multiple at
  # `^DIC(19,13112,"RPC","B",3374,20)`. RPC registration is OPTION-scoped, so
  # under any other context the broker denies them — and the AGG* RPCs are
  # absent from the defaults this gem can be sitting on: CIAV VUECENTRIC
  # (#10979, what CIA sign-on binds), CIANB MAIN MENU (#10976, what it bound
  # before 2026-09-23) and OR CPRS GUI CHART (#9649, 1004 RPCs, none of them
  # AGG*).
  #
  # Every public method here therefore scopes itself to AGGRPC via
  # ContextScope#with_context (bind, run, restore the caller's context). That
  # is deliberate: leaving the bind to the caller made Agg.available? answer
  # "not runnable HERE", which is indistinguishable from "AG not installed" —
  # so delegation silently never fired and every registration fell through to
  # a composition path (since removed, rpms-rpc#409). A client that cannot
  # scope contexts (a test double) is simply run as-is.
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
  #            CiaClient#call_rpc_global_array. (RS was the CIA EOD until
  #            #241 moved the terminator to \x7f; the default read no longer
  #            truncates at the header, but the $C(31) read is still the
  #            correct one — it is framed by the sentinel, not by luck.)
  #
  #   RPC                        routine^tag       source
  #   AGG ADD NEW PATIENT        ADD^AGGPTADD      #214 live probe
  #   AGG UPDATE PATIENT         UPD^AGGPTUPD      #214 live probe
  #   AGG PATIENT EDIT CHECK     CHK^AGGEDCHK      #214 live probe
  #   AGG LOCK PATIENT           LOCK^AGGLOCK      8994 registry (#381)
  #   AGG UNLOCK PATIENT         UNLOCK^AGGLOCK    8994 registry (#381)
  #   CIANBRPC CANRUN            CANRUN^CIANBRPC   8994 registry (#225)
  module Agg
    extend self
    extend Shape::Declarable

    # AGG* RPC names (registered in #8994 under the AGGRPC option).
    ADD_RPC = "AGG ADD NEW PATIENT"           # ADD^AGGPTADD, return type GLOBAL ARRAY
    UPDATE_RPC = "AGG UPDATE PATIENT"         # UPD^AGGPTUPD
    EDIT_CHECK_RPC = "AGG PATIENT EDIT CHECK" # CHK^AGGEDCHK
    CANRUN_RPC = "CIANBRPC CANRUN"            # CANRUN^CIANBRPC (broker gate)
    LOCK_RPC = "AGG LOCK PATIENT"             # LOCK^AGGLOCK, return type GLOBAL ARRAY
    UNLOCK_RPC = "AGG UNLOCK PATIENT"         # UNLOCK^AGGLOCK, return type GLOBAL ARRAY
    VALIDATE_RPC = "AGG WINDOW DATA VALIDATION" # VAL^AGGWVAL, return type GLOBAL ARRAY
    TEMP_HRN_RPC = "AGG GET TEMP PAT HRN"     # GTMP^AGGPTHRN, return type GLOBAL ARRAY
    DISPLAY_RPC = "AGG BUILD WINDOW DISPLAY"    # BLD^AGGWDISP, return type GLOBAL ARRAY
    VALUE_PAIR = "\x1c" # $C(28): a T or C value is INTERNAL_$C(28)_EXTERNAL (AGGWDISP.m:35-50)
    WINDOW_MULTIPLE_RPC = "AGG BUILD WINDOW MULTIPLE" # MUL^AGGPTDMG, a multiple window's entries
    TABLE_LOOKUP_RPC = "AGG WINDOW TABLE LOOKUP"      # LKP^AGGWTBLK, a pointed-to file's entries by name
    UPDATE_ALIASES_RPC = "AGG UPDATE ALIASES"         # ALIAS^AGGPTNAM
    UPDATE_SPECIAL_MULTIPLES_RPC = "AGG UPDATE SPECIAL MULTIPLES" # UPD^AGGPOTH
    UPDATE_MULTIPLE_RECORD_RPC = "AGG UPDATE A MULTIPLE RECORD" # UPD^AGGMLUPD
    QUANTUM_VALIDATION_RPC = "AGG QUANTUM VALIDATION" # QNT^AGGFTVAL
    CHECK_SENSITIVE_RPC = "AGG CHECK SENSITIVE PATIENT" # CHK^AGGPTSEN
    SEND_SENSITIVE_NOTIFY_RPC = "AGG SEND SENSITIVE NOTIFY" # NOT^AGGPTSEN
    ERROR_SCREEN_RPC = "AGG ERROR SCREEN"             # FND^AGGEDCHK
    PATIENT_LANGUAGES_RPC = "AGG PATIENT LANGUAGES"   # LANG^AGGWOTH, the latest entry's other languages

    # The context option the AGG* RPCs are registered under — file 19 IEN
    # 13112, TYPE "B", no LOCK. Every method here binds it; see the module doc.
    CONTEXT = "AGGRPC"

    # Registration window definitions (file 9009068.3). "Mini Registration"
    # (IEN 29) is the minimal demographics set; "New Patient" (IEN 28) is a
    # 28-param superset.
    DEFAULT_WINDOW = "Mini Registration"

    # "New Patient" (IEN 28) is the window AG registers a new patient through:
    # its 0-node names file 2, secondary file 9000001 and the save RPC AGG ADD
    # NEW PATIENT. Its 28 parameters are in test/fixtures/agg/
    # new_patient_window.tsv, read from ^AGG(9009068.3,28,10) on
    # bcer-9.0-20260905-ydb. ADD^AGGPTADD refuses any name not in the window's
    # "AC" index (AGGPTADD.m:44-45), so a name not in that fixture is rejected.
    # The IHS PATIENT values it carries, and how ADD^AGGPTADD files them:
    #
    #   AGGPTCLB  Classification/Beneficiary  type T -> #9000001 1111, internal
    #                                         (IEN of #9999999.25)
    #   AGGPTELG  Eligibility Status          type C -> #9000001 1112; the
    #                                         choice name ("DIRECT ONLY") or
    #                                         the code ("D") - a value that is
    #                                         not a choice name is filed as
    #                                         given (AGGPTADD.m:48-51)
    #   AGGPTTRI  Tribe of Membership         type T -> #9000001 1108, internal
    #                                         (IEN of #9999999.03)
    #   AGGPTCOM  Current Community           type T -> #9000001 1117 CURRENT
    #                                         RESIDENCE PTR, internal (IEN of
    #                                         #9999999.05)
    #   AGGPTCDT  Date Moved                  with AGGPTCOM, files the PREVIOUS
    #                                         COMMUNITY multiple (#9000001.51)
    #                                         through COMM^AGGPTADD; that entry
    #                                         is what sets 1118 CURRENT
    #                                         COMMUNITY (the text)
    #
    # Types T/C/K are filed with FILE^DIE "I" (internal, AGGPTADD.m:79-81,103),
    # so pointer values are IENs. Proven live 2026-10-02 on that image as a
    # programmer-key user: a create with these five filed 1108, 1111, 1112,
    # 1117, the #9000001.51 entry and 1118. Sending AGGPTCDT as "B" (at birth,
    # which the GUI resolves before it sends) filed no #9000001.51 entry.
    NEW_PATIENT_WINDOW = "New Patient"

    # PARMS framing bytes.
    PARM_DELIM = "\x1c" # $C(28) — NAME=VALUE separator in the PARMS string
    RECORD_SEP = "\x1e" # $C(30) — record separator in the reply
    ARRAY_END  = "\x1f" # $C(31) — end-of-array sentinel
    ACK = "\x00"        # broker ack byte following the 1-byte sequence echo

    # Is the AGG registration suite installed and runnable for this client?
    #
    # ## The wire argument is the RPC NAME, not the file-8994 IEN (#225)
    #
    # The registered entry is `^XWB(8994,…,0) = "CIANBRPC CANRUN^CANRUN^
    # CIANBRPC^1"` — TAG `CANRUN`, ROUTINE `CIANBRPC`, return type 1 (SINGLE
    # VALUE). So the wire entry point is CANRUN^CIANBRPC, which resolves the
    # IEN ITSELF and only then delegates to the CANRUN^CIANBACT helper:
    #
    #   CANRUN(DATA,RPC) ;                              CIANBRPC.m:173-175
    #    S DATA=$$CANRUN^CIANBACT($$FIND1^DIC(8994,,"QX",RPC),CIA("CTX"))
    #
    # `$$FIND1^DIC(8994,,"QX",RPC)` is a quick ("Q") exact-match ("X") "B"-index
    # lookup returning the IEN, or "" when the name is absent or ambiguous
    # (DIC.m:87-106, `S DIFIND=+$G(DITARGET(1))` at :102). Passing the NAME
    # here is therefore the correct contract; passing an IEN would be the
    # defect — FIND1 would fail to resolve it, the inner call would receive ""
    # and quit 0. Only the INNER CANRUN^CIANBACT takes an IEN.
    #
    #   CANRUN(RPC,CTX) ;                               CIANBACT.m:142-148
    #    Q:'$G(DUZ)!'RPC 0                ; not signed on, or name unresolved
    #    S CTX(0)=$$OPTLKP^CIANBUTL(CTX)
    #    Q:$$ERRCHK('$L(CTX(0)),2,CTX) 0  ; CIA("CTX") missing/unresolvable
    #    D:'$G(^XTMP("CIA",CIA("UID"),"C",CTX(0))) BLDCTX(CTX(0))
    #    Q:$$KCHK^XUSRB("XUPROGMODE") 1   ; privileged bypass
    #    Q $D(^XTMP("CIA",CIA("UID"),"C",CTX(0),RPC))
    #
    # The answer comes from the context option's RPC multiple — the "B" index
    # merged at CIANBACT.m:155 (`M ^XTMP(…)=^DIC(19,OPT,"RPC","B")`), whose
    # subscripts are 8994 IENs. This is real registry evidence (rpms-rpc#209,
    # #214): the gate reads the option's RPC list rather than executing the
    # (write) RPC, so probing never files anything.
    #
    # ## The question is per CONTEXT, so this method binds one
    #
    # CANRUN answers "is this RPC in the CURRENT context option", so the probe
    # only means "is AG installed" when it runs under AGGRPC — which is why
    # this scopes itself (module doc). Asking under CIAV VUECENTRIC, CIANB MAIN
    # MENU or OR CPRS GUI CHART is answered a truthful 0 because AGG* is not
    # registered there.
    # Note the context check (:145) precedes the XUPROGMODE bypass (:147): a
    # session whose CIA("CTX") does not resolve is answered 0 even for a
    # programmer.
    #
    # ## The XUPROGMODE caveat, stated honestly
    #
    # Once a context resolves, a session holding XUPROGMODE is answered 1
    # unconditionally (:147). Such a session therefore CANNOT prove this gate
    # either way — not that AGG is present, and not that the context bind
    # works. Only a NON-privileged session is evidence; that live proof is
    # rpms-rpc#224 and has NOT been run. The tests prove the Ruby side only.
    #
    # ## Failing closed
    #
    # Every path that cannot establish availability — a "0" answer, an empty
    # reply, a context that will not bind, an RpcError — returns false and
    # WARNS. RpmsRpc::Registration does not ask: it calls AG and lets a
    # refusal surface (rpms-rpc#409).
    def available?(client = RpmsRpc.client)
      in_context(client) { canrun?(client) }
    rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError => e
      warn "[rpms_rpc] AGG delegation unavailable: could not evaluate the " \
           "#{CONTEXT} gate (#{e.class})"
      false
    end

    # FND^AGGPTLKP's $C(28) branch searches by name OR DOB (LST2), using
    # the same XLFNAME1 formatter as ADD. Include every division and inactive
    # chart. Send all name pieces, including empty ones, to clear server
    # locals left by an earlier call. Candidates require review, not a Ruby
    # guess that a different DOB/sex makes a name collision safe (#407).
    def registration_candidates(params)
      require_relative "patient"

      names = %w[AGGPTLNM AGGPTFNM AGGPTMNM AGGPTSFX AGGPTDOB]
      text = encode_parms(names.to_h { |name| [ name, params[name].to_s ] })
      in_context(RpmsRpc.client) do
        Patient.lookup(text, all_divisions: true, include_inactive: true, require_response: true)
      end
    end

    # ADD^AGGPTADD — create a patient from a demographics PARMS hash.
    # Returns { success: true, dfn:, message: } on "1^^DFN",
    # { success: false, error: :agg_rejected, message: } on "-1^message",
    # or nil when the broker gives no response.
    def add_patient(params:, window: DEFAULT_WINDOW, dfn: "", client: RpmsRpc.client)
      in_context(client) do
        interpret_write(call_array(client, ADD_RPC, window, dfn.to_s, encode_parms(params)), require_dfn: true)
      end
    end
    shape :add_patient, resource: "agg", verb: "POST", path: "/agg/patient"

    # UPD^AGGPTUPD — edit an existing patient (DFN required). Same PARMS
    # convention and reply shape as ADD (header RESULT^ERROR^OTHER_PARMS).
    # AG's own check of one window field, VAL^AGGWVAL: the call AG's client makes
    # before it saves. The field checked is the FIRST parameter (VAL takes the
    # validation tag from the first one the window defines one for); send that
    # field's companions with it, and DFN ("" for a new patient), which the tag is
    # called with: left undefined it is an M error and the broker job hangs.
    #
    # Returns { valid: true }, { valid: false, message: } for RESULT -1 (1 and 0
    # are not refusals), or nil when RPMS gave no result row: the tag errored
    # (openrpms#1040) or the broker did not answer.
    def validate_field(params:, window: DEFAULT_WINDOW, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, VALIDATE_RPC, window, encode_parms(params))) }
      result = reply&.dig(:records, 0, :result).to_s
      return nil unless result.match?(/\A-?\d+\z/)

      result.to_i.negative? ? { valid: false, message: reply[:records][0][:msg].to_s } : { valid: true }
    end
    shape :validate_field, resource: "agg", verb: "POST", path: "/agg/validate-field"

    # BLD^AGGWDISP — what AG's own window shows for a patient: the read AG's
    # client makes before an edit. P1 = window name, P2 = DFN. The reply's
    # header names each displayed parameter (a parameter whose node 0 piece 11
    # is set is not displayed, AGGWDISP.m:23, so Address carries no email) and
    # its one record holds the values: a T (pointer) or C (choice) value is
    # INTERNAL_$C(28)_EXTERNAL, a D (date) value is AG's external date
    # ($$FMTE^AGGUL1), the rest are text (AGGWDISP.m:27-79). No record means
    # every value is empty (AGGWDISP.m:83).
    #
    # Returns { "PARAMETER" => value } with T and C values as
    # { internal:, external: } (both nil when empty), or nil when the broker
    # gives no reply or AG answers without its header (an unknown window).
    def window_values(window:, dfn:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, DISPLAY_RPC, window, dfn.to_s)) }
      return nil if reply.nil? || reply[:header].empty?

      record = reply[:records].first || {}
      reply[:header].to_h do |name|
        value = record[name].to_s.dup.force_encoding(Encoding::UTF_8)
        [ name.to_s.upcase, value.include?(VALUE_PAIR) ? pair(value) : value ]
      end
    end
    shape :window_values, resource: "agg", verb: "POST", path: "/patients/{dfn}/agg/window-values"

    def update_patient(dfn:, params:, window: DEFAULT_WINDOW, client: RpmsRpc.client)
      in_context(client) do
        interpret_write(call_array(client, UPDATE_RPC, window, dfn.to_s, encode_parms(params)))
      end
    end
    shape :update_patient, resource: "agg", verb: "PUT", path: "/patients/{dfn}/agg"


    # MUL^AGGPTDMG: the entries of a multiple window (P1 window, P2 the node of the
    # multiple under the patient's record, P3 the DFN, P4 one entry or "" for all).
    # Returns the records, or nil when RPMS did not answer.
    def window_multiple(window:, node:, dfn:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, WINDOW_MULTIPLE_RPC, window, node.to_s, dfn.to_s, "")) }
      reply && reply[:records]
    end
    shape :window_multiple, resource: "agg", verb: "GET", path: "/patients/{dfn}/agg/window-multiple"

    # LKP^AGGWTBLK: the entries of a pointed-to file whose name starts with the
    # text (FIND^DIC, AGGWTBLK.m), the look-up AG's client runs for a table
    # field. Returns [{ ien:, name: }], [] when none match, or nil when RPMS did
    # not answer. The text must not be empty: LKP refuses it.
    def table_lookup(file:, text:, client: RpmsRpc.client)
      text = text.to_s.strip
      raise ArgumentError, "a look-up needs text" if text.empty?

      reply = in_context(client) { parse_reply(call_array(client, TABLE_LOOKUP_RPC, file.to_s, text, "")) }
      return nil if reply.nil?

      # The name is the second column, read by position: a file's header can
      # name two columns alike (STATE's is IEN^NAME^VA_STATE_CODE^NAME), and the
      # record hash keeps only the last of them.
      reply[:rows].map { |pieces| { ien: pieces[0].to_i, name: pieces[1].to_s } }
    end
    shape :table_lookup, resource: "agg", verb: "GET", path: "/agg/files/{file}/table-lookup"

    # ALIAS^AGGPTNAM: add ("A") or delete ("D") one entry of the PATIENT ALIAS
    # multiple (#2.01). An add files the name through FILE^DICN with no input
    # transform, so a caller checks the name first. Reply header
    # "I00010RESULT^T01024ERROR^I00010RIEN"; returns { success: true, ien: } or
    # { success: false, error: :agg_rejected, message: }, nil for no reply.
    def update_aliases(dfn:, action:, ien: "", params: {}, client: RpmsRpc.client)
      in_context(client) do
        interpret_entry_write(call_array(client, UPDATE_ALIASES_RPC, dfn.to_s, action.to_s, ien.to_s, encode_parms(params)))
      end
    end
    shape :update_aliases, resource: "agg", verb: "PUT", path: "/patients/{dfn}/agg/aliases"

    # UPD^AGGPOTH: add ("A") or delete ("D") one entry of a multiple below a
    # dated entry, for the window "Other Languages" (#9000001.8605 under a
    # LANGUAGES ENTRY DATE) or "Internet Access Method". P3 is the DFN, P4 the
    # dated entry's IEN. Returns { success: true } or { success: false, ... }.
    def update_special_multiple(window:, dfn:, entry:, action:, params:, client: RpmsRpc.client)
      in_context(client) do
        interpret_entry_write(call_array(client, UPDATE_SPECIAL_MULTIPLES_RPC, window, dfn.to_s, entry.to_s, action.to_s,
                                         encode_parms(params)))
      end
    end
    shape :update_special_multiple, resource: "agg", verb: "PUT", path: "/patients/{dfn}/agg/special-multiple"

    # UPD^AGGMLUPD: add ("A") or delete ("D") one entry of a multiple under the
    # patient, for the window "Other Tribe" (#9000001.43). P3 is the DFN, P4 the
    # entry, "" to add. Returns { success: true } or { success: false, ... }.
    def update_multiple_record(window:, dfn:, action:, entry: "", params: {}, client: RpmsRpc.client)
      in_context(client) do
        interpret_entry_write(call_array(client, UPDATE_MULTIPLE_RECORD_RPC, window, action.to_s, dfn.to_s, entry.to_s,
                                         encode_parms(params)))
      end
    end
    shape :update_multiple_record, resource: "agg", verb: "PUT", path: "/patients/{dfn}/agg/multiple-record"

    # QNT^AGGFTVAL: whether a new other tribe's quantum, with the tribe of
    # membership's and every other tribe's, stays within the Indian blood
    # quantum. AG skips it unless the patient is Indian/Alaska Native and the
    # facility records tribal quantums. others: the quantums already on file.
    # Returns { valid: true } or { valid: false, message: }, or nil when RPMS
    # did not answer.
    def quantum_check(tribe:, quantum:, membership:, membership_quantum:, blood_quantum:, classification:, others: [],
                      client: RpmsRpc.client)
      reply = in_context(client) do
        parse_reply(call_array(client, QUANTUM_VALIDATION_RPC, tribe.to_s, quantum.to_s, membership.to_s, membership_quantum.to_s,
                               blood_quantum.to_s, classification.to_s, others.empty? ? "" : "AGGOTTRQ=#{others.join("\x1d")}"))
      end
      return nil if reply.nil?

      record = reply[:records].first
      return { valid: true } if record.nil? || record[:result].to_s == "1"

      { valid: false, message: record[:error].to_s }
    end
    shape :quantum_check, resource: "agg", verb: "POST", path: "/agg/quantum-check"

    # LANG^AGGWOTH: the other languages of the patient's latest LANGUAGES ENTRY
    # DATE (#9000001.86) entry, as [{ ien:, name: }], or nil when RPMS did not
    # answer.
    def patient_languages(dfn:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, PATIENT_LANGUAGES_RPC, dfn.to_s)) }
      return nil if reply.nil?

      reply[:records].map do |row|
        ien, name = row[:agglgoth].to_s.split(PARM_DELIM, 2)
        { ien: ien.to_i, name: name.to_s }
      end
    end
    shape :patient_languages, resource: "agg", verb: "GET", path: "/patients/{dfn}/agg/languages"

    # Run the block holding AG's own edit lock on the patient, under AGGRPC,
    # and release it afterward. This is the lock AG ships for editing a
    # registration ("This event is locked for editing by ...", AGGLOCK.m:50;
    # the GUI that calls it is not in FOIA, so its call order is not
    # visible). LOCK^AGGLOCK (AGG LOCK PATIENT, P1 = DFN) takes
    # ^DPT(DFN) and then ^AUPNPAT(DFN), each with a 1-second timeout
    # (AGGLOCK.m:40-41), and records who holds it in ^XTMP("AGGLCK",DFN)
    # (AGGLOCK.m:52-55). UPD^AGGPTUPD takes no lock of its own, so without
    # this two editors could interleave. UNLOCK^AGGLOCK releases both
    # (AGGLOCK.m:85,109-119). Both are registered under AGGRPC (the
    # captured registry and reach files in data/inventories/).
    #
    # Reply: header "I00010RESULT^T00080MESSAGE" (AGGLOCK.m:27), then
    # RESULT^MESSAGE (AGGLOCK.m:91): 1 locked, 0 held by someone else (the
    # MESSAGE names who, AGGLOCK.m:46-50), -1 no such patient in #2 or
    # #9000001 (AGGLOCK.m:34-35,104-107).
    #
    # Returns the block's value. When the lock is not taken it does not
    # yield, and returns { success: false, error: :lock_failed, message: }
    # (:invalid_dfn for -1). No reply counts as not taken.
    def editing(dfn:, client: RpmsRpc.client)
      in_context(client) do
        lock = lock_result(parse_reply(call_array(client, LOCK_RPC, dfn.to_s)))
        if lock
          lock
        else
          begin
            yield
          ensure
            call_array(client, UNLOCK_RPC, dfn.to_s)
          end
        end
      end
    end

    # CHK^AGGEDCHK — the completeness edit-check battery for a patient.
    # Exposed for UX-grade validation feedback; NOT an integrity gate.
    # Returns { checks: [{ hide_error_num:, msg:, type: ("MANDATORY" /
    # "WARNING"), ... }] } or nil (no response).
    def edit_check(dfn:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, EDIT_CHECK_RPC, dfn.to_s)) }
      return nil if reply.nil?

      { checks: reply[:records] }
    end

    # CHK^AGGPTSEN — sensitive-patient indicator for this user. Option: AGGRPC.
    # A DFN that is not a positive integer raises ArgumentError before any
    # RPC. The wire value is the canonical digit string. The row is 0, 1,
    # or 2 (AGGPTSEN.m:16-19). Anything else, including a blank that would
    # coerce to 0, is nil: 0 means "not sensitive". CHK calls SENS^DGSEC4
    # (AGGPTSEN.m:30). SENS audits the lookup (ACCESSED^DIET, DGSEC4.m:178)
    # only when the DI AUDIT PATIENT LOOKUPS parameter is set. It does not write
    # the DG SECURITY LOG: that SETLOG1 write (DGSEC4.m:65) is in PTSEC, after
    # SENS returns, and CHK does not call PTSEC. The write class stays
    # :non_idempotent_write because the audit can write. Returns
    # { sensitive_indicator: Integer } or nil.
    def check_sensitive_patient(dfn:, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      raise ArgumentError, "DFN must be a positive integer" unless id

      reply = in_context(client) { parse_reply(call_array(client, CHECK_SENSITIVE_RPC, id)) }
      raw = reply&.dig(:records, 0, :sensitive_indicator).to_s
      return nil unless raw.match?(/\A[012]\z/)

      { sensitive_indicator: raw.to_i }
    end
    shape :check_sensitive_patient, resource: "agg", verb: "POST", path: "/patients/{dfn}/agg/check-sensitive"

    # NOT^AGGPTSEN — file the sensitive-record bulletin. Option: AGGRPC.
    # A DFN that is not a positive integer raises ArgumentError before any
    # RPC. The wire value is the canonical digit string. The routine
    # hardcodes the option it logs (AGGPTSEN.m:59). Success is RESULT "1"
    # only. Returns { success: } or nil when RPMS did not answer.
    def send_sensitive_notify(dfn:, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      raise ArgumentError, "DFN must be a positive integer" unless id

      in_context(client) do
        parsed = parse_reply(call_array(client, SEND_SENSITIVE_NOTIFY_RPC, id))
        return nil if parsed.nil?

        record = parsed[:records].first
        if record.nil?
          { success: false, message: "AGG SEND SENSITIVE NOTIFY gave no data record" }
        else
          { success: record[:result].to_s == "1" }
        end
      end
    end
    shape :send_sensitive_notify, resource: "agg", verb: "POST", path: "/patients/{dfn}/agg/send-sensitive-notify"

    # FND^AGGEDCHK — the window and field for an edit-check error number.
    # Option: AGGRPC. An empty ERRNUM walks the whole error file
    # (AGGEDCHK.m:66). On the pinned routine FER's data-row write is
    # commented out (AGGEDCHK.m:77), so a live call returns the header
    # only; that is [], not an error. A data row ERROR_NUM^WINDOW^FIELD
    # is still parsed when one is present.
    # Returns [{ error_num:, window:, field: }] or nil when RPMS did not answer.
    def error_screen(errnum:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, ERROR_SCREEN_RPC, errnum.to_s)) }
      return nil if reply.nil?

      reply[:records].map do |row|
        { error_num: row[:error_num].to_s, window: row[:window].to_s, field: row[:field].to_s }
      end
    end
    shape :error_screen, resource: "agg", verb: "GET", path: "/agg/error-screen"

    # GTMP^AGGPTHRN — the next temporary health record number for a patient,
    # the T-number IHS scheduling's mini-registration gives a caller who has
    # no chart yet (option BSDAM MINI REGISTRATION, key SDZREGMENU: "assigns
    # a temporary chart number"). AG takes the highest "T" number in the
    # IHS PATIENT "D" index and adds one, or returns the one this patient
    # already holds (AGGPTHRN.m:20-31), and reserves it by setting
    # ^AUPNPAT("D",THRN,DFN,DUZ(2)) (AGGPTHRN.m:15). It does not file the
    # HEALTH RECORD NO. multiple: the caller files the number through AGG
    # UPDATE PATIENT, as RpmsRpc::Registration does.
    #
    # Reply: header "T00010AGGPTHRN", then the number (AGGPTHRN.m:13-16).
    # Returns the number ("T00001"), or nil when RPMS gave none.
    def temporary_hrn(dfn:, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, TEMP_HRN_RPC, dfn.to_s)) }
      number = reply&.dig(:records, 0, :aggpthrn).to_s
      number.match?(/\AT\d{5}\z/) ? number : nil
    end
    shape :temporary_hrn, resource: "agg", verb: "POST", path: "/patients/{dfn}/agg/temporary-hrn"

    # Encode a NAME=VALUE PARMS hash as the $C(28)-delimited string P3.
    # nil values are dropped; everything is sent as-is (FileMan-external —
    # AGGPTSEX is the coded set value "MALE"/"FEMALE", dates MM/DD/YYYY).
    def encode_parms(params)
      if params.any? { |name, value| name.to_s.include?(PARM_DELIM) || value.to_s.include?(PARM_DELIM) }
        raise ArgumentError, "AG parameters must not contain the parameter delimiter"
      end

      params.reject { |_, v| v.nil? }
            .map { |name, value| "#{name}=#{value}" }
            .join(PARM_DELIM)
    end

    # Parse a raw GLOBAL ARRAY reply into { header: [names], records:
    # [{name => value}] }. Strips the leading sequence echo + \x00 ack, cuts
    # at the $C(31) end sentinel, splits records on $C(30), and maps each
    # record's "^"-pieces onto the typed-header field names. nil on an empty
    # reply. A line Array (BMX/XWB #call_rpc, which strip the separators, or a
    # seeded array that keeps them) is rejoined into the same blob first;
    # a String is untouched.
    def parse_reply(raw)
      return nil if raw.nil?

      raw = lines_to_blob(raw) if raw.is_a?(Array)
      body = raw.to_s.b
      body = body.split(ACK, 2).last.to_s if body.include?(ACK)
      body = body.split(ARRAY_END, 2).first.to_s
      return nil if body.empty?

      rows = body.split(RECORD_SEP)
      return nil if rows.empty?

      names = parse_header(rows.shift)
      split = rows.reject(&:empty?).map { |row| row.split("^", -1) }
      records = split.map { |pieces| names.each_with_index.to_h { |name, i| [ name, pieces[i] ] } }
      { header: names, records: records, rows: split }
    end

    # A DFN subscript these routines can use: a positive Integer, or a
    # String matching /\A[1-9]\d*\z/ with no strip. The canonical wire
    # string, or nil. "0990031" and " 990031" are not patient 990031.
    # Sends nothing.
    def canonical_dfn(dfn)
      case dfn
      when Integer
        dfn.positive? ? dfn.to_s : nil
      when String
        dfn.match?(/\A[1-9]\d*\z/) ? dfn : nil
      end
    end

    private

    # Rows of a line Array as one blob: each row ends in exactly one $C(30),
    # whether or not the client already stripped it, and the $C(31) sentinel
    # is dropped (parse_reply cuts there anyway).
    def lines_to_blob(lines)
      lines.map { |line| line.to_s.delete(RECORD_SEP + ARRAY_END) }
           .reject(&:empty?)
           .map { |row| row + RECORD_SEP }
           .join
    end

    # Bind AGGRPC for the duration of the block and restore the caller's
    # context afterward (ContextScope#with_context — a no-op round-trip-wise
    # when AGGRPC is already bound, so nesting these is free). A client that
    # cannot scope contexts — a MockClient, any non-broker double — runs the
    # block as-is.
    def in_context(client, &block)
      return block.call unless client.respond_to?(:with_context)

      client.with_context(CONTEXT, &block)
    end

    # The CANRUN scalar, read through the client's reply grammar (CiaClient#parse_cia_reply):
    # a \x00 reply yields its lines, a \x01 reply raises RpcError (which available? turns into
    # "not available"), and a bare sequence echo yields nothing. Never the raw frame: on an
    # error reply the first byte is the sequence echo, and reading it as the answer would call
    # AGG available when CANRUN said nothing of the kind. CANRUN answers with a $DATA value
    # (CIANBACT.m:148): 1, 10 or 11 when the context lists the RPC, 0 when it does not; only
    # the XUPROGMODE bypass answers a literal 1. Any positive value is yes.
    def canrun?(client)
      lines = if client.respond_to?(:call_rpc_lines)
        client.call_rpc_lines(CANRUN_RPC, ADD_RPC)
      else
        client.call_rpc(CANRUN_RPC, ADD_RPC)
      end
      Array(lines).first.to_s.strip.to_i.positive?
    end

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

    def pair(value)
      internal, external = value.split(VALUE_PAIR, 2)
      { internal: internal.to_s.empty? ? nil : internal, external: external.to_s.empty? ? nil : external }
    end

    # nil when the lock was taken; the failure hash otherwise.
    def lock_result(parsed)
      record = parsed && parsed[:records].first
      return { success: false, error: :lock_failed, message: "AGG LOCK PATIENT gave no reply" } if record.nil?
      return nil if record[:result].to_s == "1"

      error = record[:result].to_s == "-1" ? :invalid_dfn : :lock_failed
      { success: false, error: error, message: record[:message].to_s }
    end

    # A write whose reply is RESULT^ERROR[^RIEN]: ALIAS^AGGPTNAM and UPD^AGGPOTH.
    def interpret_entry_write(reply)
      parsed = parse_reply(reply)
      return nil if parsed.nil?

      record = parsed[:records].first
      return { success: false, error: :agg_empty_reply, message: "AGG reply carried no data record" } if record.nil?
      return { success: false, error: :agg_rejected, message: record[:error].to_s } unless record[:result].to_s == "1"

      record[:rien].to_s.empty? ? { success: true } : { success: true, ien: record[:rien].to_i }
    end

    # require_dfn: ADD^AGGPTADD always fills the DFN piece on success, so a
    # "1" result with a blank DFN is a malformed/partial reply for the add
    # path; UPD^AGGPTUPD legitimately returns "1^" with no DFN.
    def interpret_write(reply, require_dfn: false)
      parsed = parse_reply(reply)
      return nil if parsed.nil?

      record = parsed[:records].first
      return { success: false, error: :agg_empty_reply, message: "AGG reply carried no data record" } if record.nil?

      message = record[:message] || record[:error] || ""
      if record[:result].to_s == "1"
        dfn = record[:dfn].to_s
        if dfn.empty? && require_dfn
          return { success: false, error: :agg_malformed_reply,
                   message: "AGG success record carried no DFN" }
        end
        result = { success: true, dfn: dfn.empty? ? nil : dfn.to_i, message: message.to_s }
        # UPD^AGGPTUPD's OTHER_PARMS names what a filing code created, e.g.
        # "AGGLNG=7" for a new LANGUAGES ENTRY DATE entry (ULNG^AGGPOTH).
        other = record[:other_parms].to_s
        other.empty? ? result : result.merge(other_parms: other)
      else
        text = message.to_s.empty? ? record.values.compact.join("^") : message.to_s
        { success: false, error: :agg_rejected, message: text }
      end
    end
  end
end
