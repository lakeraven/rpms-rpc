# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../context_scope"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for the problem list. Read via ORQQPL LIST and the other
  # ORQQPL reads below; write through IHS's BGOPROB SET / BGOPROB DEL, the
  # writes VueCentric uses on RPMS (rpms-rpc#527). Stock ORQQPL stays
  # read-only here: its writes carry none of SNOMED CT, laterality or the
  # location-scoped problem number.
  module Problem
    extend self
    extend Shape::Declarable

    # "P"-line pieces after the "P" marker for SET^BGOPROB's ARRAY param
    # (BGOPROB.m:229-233 on the pinned build; parsed in PROB^BGOPROB3:
    # SNOMED CT [2], Descriptive CT [3], Provider text [4], Mapped ICD [5],
    # Location [6], Onset [7], Status [8], Class [9], Problem # [10],
    # Priority [11]). The list locks the order so a caller's Hash key
    # insertion order can't reshuffle the payload mid-flight.
    PROB_FIELDS = %i[snomed_ct descriptive_ct description icd_code location_ien
                     onset_date status problem_class problem_number priority].freeze

    # The option that carries BGOPROB SET / DEL and DDR GETS ENTRY DATA on
    # the pinned build (the context CIA sign-on binds).
    CONTEXT = "CIAV VUECENTRIC"
    PROBLEM_FILE = "9000011"

    # List a patient's problems. Underlying RPC: ORQQPL LIST — verified row
    # shape IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^SC^SPEXP^... (see
    # the :problem_list mapping). An inactive-ICD row (ORQQPL.m:15-16:
    # piece 13 "#", whatever piece 4 holds) yields inactive_icd true and
    # transcribed nil; a retired code there is kept as icd_code, flagged by
    # inactive_icd (#532). On every row icd_code keeps piece 4 only when it is
    # code-shaped after surrounding whitespace is stripped (ICD-10-CM or
    # ICD-9-CM, PROBLEM_LIST_ICD_CODE_SHAPE). Anything else — any
    # $$ICDDX/^ICDCODE failure text, "-1", empty — is nil, and a code-shaped
    # value is the stripped token. Every other
    # row has inactive_icd false. "No
    # problems" comes back as the sentinel row "^No problems found."
    # (LIST^ORQQPL: ORQQPL.m:17) — no IEN, so it
    # is dropped rather than surfaced as a phantom problem. Invalid DFNs
    # short-circuit to [] without dispatching an RPC.
    #
    # Formals: LIST(ORPY,DFN,STATUS) (ORQQPL.m:3-5) — STATUS "A" active,
    # "I" inactive, "" all. STATUS is read unconditionally, so it goes over
    # the wire even when empty; a DFN-only frame died in M on it (#259).
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.problem_list.fetch_many(dfn.to_s, "").reject { |r| r[:ien].to_s.empty? }
    end
    shape :for_patient, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems"

    # Add a problem: SET^BGOPROB with PRIEN empty. The gem sends SPEC=1, so
    # the routine files the caller's ICD (:icd_code) rather than deriving one
    # from SNOMED CT (PROB^BGOPROB3, BGOPROB3.m:94-95), and needs a location
    # (:location_ien, the INSTITUTION the problem is numbered under; -1049
    # without one, BGOPROB3.m:125). The reply is the new problem's IEN
    # (BGOPROB3.m:183) or -CODE^text.
    #
    # The new entry is read back with DDR. The build answers an IEN for an
    # ICD code it cannot resolve and files the problem with .01 = -1
    # ($$ICDDX^ICDEX answers "-1^..." and `I 'DIEN` does not catch it,
    # BGOPROB3.m:121-122), so a read-back whose .01 is not a positive
    # pointer, or whose .02 is not the patient, is a failure (:not_filed),
    # with the IEN the build gave.
    #
    # Returns { success:, ien:, raw: }, plus error: on a refusal.
    def add(dfn, problem)
      raise ArgumentError, "problem must be a Hash" unless problem.is_a?(Hash)
      return failure if invalid_id?(dfn)

      in_context { write(dfn, nil, problem) }
    end
    shape :add, resource: "problems", verb: "POST", path: "/patients/{dfn}/problems"

    # Edit a problem: SET^BGOPROB with PRIEN set. SET does not check that
    # the problem is the patient's (it only checks the patient exists,
    # BGOPROB3.m:117, and leaves .02 alone on an edit), so the gem reads the
    # problem first and sends nothing unless its .02 is this patient
    # (:not_found, :wrong_patient). The edit is read back as add's is.
    def update(dfn, ien, changes)
      raise ArgumentError, "changes must be a Hash" unless changes.is_a?(Hash)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      in_context do
        refused = refuse_unless_patients(dfn, ien)
        refused || write(dfn, ien, changes)
      end
    end
    shape :update, resource: "problems", verb: "PUT", path: "/patients/{dfn}/problems/{ien}"

    # Logical delete via DEL^BGOPROB -> DEL^BGOPROB3: .12 STATUS "D" plus
    # 2.01-2.04 (who, when, reason, comment). Param: IEN ^ TYPE ^ REASON ^
    # COMMENT ^ PROB ID. DEL answers "" on success, and also "" for a
    # problem IEN not on file (BGOPROB3.m:18), so the gem reads the problem
    # first (:not_found, :wrong_patient; nothing sent) and reads .12 back
    # after: anything but "D" is :not_filed. A problem a visit, care plan,
    # visit instruction or OB note uses is refused by the build as -1^text
    # (CHK^BGOPROB2).
    def delete(dfn, ien, reason:)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      in_context do
        refused = refuse_unless_patients(dfn, ien)
        next refused if refused

        # Client called directly: DEL returns "" on success, which
        # fetch_scalar would collapse into nil (indistinguishable from
        # broker silence — and silence must never read as a delete).
        raw = RpmsRpc.client.call_rpc(DataMapper.problem_remove.rpc_name, "#{ien}^^#{reason}")
        next { success: false, ien: nil, raw: raw } unless DataMapper.write_accepted?(raw)

        filed = problem_fields(ien)
        next { success: true, ien: ien.to_i, raw: raw } if filed.is_a?(Hash) && filed[".12"] == "D"

        { success: false, ien: ien.to_i, raw: raw, error: :not_filed }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end
    shape :delete, resource: "problems", verb: "DELETE", path: "/patients/{dfn}/problems/{ien}"

    # ORQQPL stock-VistA reads. Use these when the engine wants the
    # stock-VistA lookup/audit surface rather than the IHS BGOPROB writes
    # above. Returns nil / [] for invalid identifiers without raising; a
    # broker that does not serve the RPC raises RpcNotAvailableError, and one
    # that serves it but not to this user raises RpcRefusedError (#363).

    def lex_search(text)
      return [] if text.to_s.strip.empty?

      Array(DataMapper.problem_lex_search.fetch_many(text.to_s))
    end
    shape :lex_search, resource: "problems", verb: "GET", path: "/problems/lex-search"

    def clinic_search(clinic_ien)
      return [] if invalid_id?(clinic_ien)

      Array(DataMapper.problem_clinic_search.fetch_many(clinic_ien.to_s))
    end
    shape :clinic_search, resource: "problems", verb: "GET", path: "/problems/clinics/{clinic_ien}/search"

    # Formals: DETAIL(Y,DFN,PROBIEN,ID) (ORQQPL.m:21) — the problem IEN is
    # the third formal, after the patient; ID is declared but never read
    # (ORQQPL.m:21-45). An IEN-only frame put the IEN in DFN and died in M
    # on PROBIEN (#259).
    def details(dfn, ien)
      return nil if invalid_id?(dfn) || invalid_id?(ien)

      DataMapper.problem_detail.fetch_one(dfn.to_s, ien.to_s)
    end
    shape :details, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/{ien}"

    def audit_history(ien)
      return [] if invalid_id?(ien)

      Array(DataMapper.problem_audit_history.fetch_many(ien.to_s))
    end
    shape :audit_history, resource: "problems", verb: "GET", path: "/problems/{ien}/audit-history"

    def comments(ien)
      return [] if invalid_id?(ien)

      Array(DataMapper.problem_comments.fetch_many(ien.to_s))
    end
    shape :comments, resource: "problems", verb: "GET", path: "/problems/{ien}/comments"

    def init_patient(dfn)
      return nil if invalid_id?(dfn)

      DataMapper.problem_init_patient.fetch_one(dfn.to_s)
    end
    shape :init_patient, resource: "problems", verb: "POST", path: "/patients/{dfn}/problems/init"

    def provider_list(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.problem_provider_list.fetch_many(dfn.to_s))
    end
    shape :provider_list, resource: "problems", verb: "GET", path: "/patients/{dfn}/problems/provider-list"

    # Formals: EDLOAD(RETURN,DA,GMPROV,GMPVAMC) (ORQQPL1.m:83) — the problem
    # IEN, then the provider DUZ, then the facility: an INSTITUTION (#4) IEN,
    # DUZ(2) in the roll-and-scroll Problem List (GMPLUTL.m:89). The pinned
    # registry names them IFN, provider, vamc. GETFLDS^GMPLEDT3 reads
    # GMPVAMC unconditionally to find the facility's note multiple
    # (GMPLEDT3.m:55) and GMPROV to keep only that provider's notes
    # (GMPLEDT3.m:57); an IEN-only frame died in M on GMPVAMC (#364).
    def edit_load(ien, provider_duz:, institution_ien:)
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?
      raise ArgumentError, "institution_ien is required (got nil)" if institution_ien.nil?
      return nil if invalid_id?(ien)

      DataMapper.problem_edit_load.fetch_one(ien.to_s, provider_duz.to_s, institution_ien.to_s)
    end

    private

    # SET^BGOPROB formals after RET: DFN, PRIEN, VIEN, ARRAY, SPEC, PIP
    # (BGOPROB.m:242). SPEC=1 takes the caller's mapped ICD.
    def write(dfn, ien, fields)
      raw = DataMapper.problem_set.fetch_scalar(
        dfn.to_s, ien.to_s, "", [ build_p_line(fields) ], "1"
      )

      saved_ien = raw.to_s.match(/\A[1-9]\d*\z/)&.to_s&.to_i
      return { success: false, ien: nil, raw: raw } unless saved_ien

      filed = problem_fields(saved_ien)
      if filed.is_a?(Hash) && filed[".02"] == dfn.to_s && filed[".01"].to_s.match?(/\A[1-9]\d*\z/)
        { success: true, ien: saved_ien, raw: raw }
      else
        { success: false, ien: saved_ien, raw: raw, error: :not_filed }
      end
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end

    # nil when problem `ien` is on file for patient `dfn`; else the refusal:
    # :not_found, :unreadable (see problem_fields) or :wrong_patient.
    def refuse_unless_patients(dfn, ien)
      filed = problem_fields(ien)
      return failure.merge(error: filed) if filed.is_a?(Symbol)
      return failure.merge(error: :wrong_patient) unless filed[".02"] == dfn.to_s

      nil
    end

    # PROBLEM (#9000011) .01, .02 and .12, internal. :not_found when
    # GETS^DIQ answers an error for the entry; :unreadable when the read
    # cannot be trusted: no reply, or one DdrFileman marks malformed, stray
    # (a field may have been read twice, the later value kept) or altered.
    def problem_fields(ien)
      entry = DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: ".01;.02;.12", flags: "I")
      return :unreadable if entry.nil? || entry[:malformed] || entry[:stray] || entry[:altered]
      return :not_found if entry[:error] || entry[:fields].empty?

      entry[:fields].transform_values { |f| f[:internal].to_s }
    end

    def in_context(&) = ContextScope.scoped(RpmsRpc.client, CONTEXT, &)

    def build_p_line(fields)
      ([ "P" ] + PROB_FIELDS.map { |k| fields[k].to_s }).join("^")
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
