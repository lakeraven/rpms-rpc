# frozen_string_literal: true

require_relative "../mappings"
require_relative "../shape"

module RpmsRpc
  # Symbolic API for the problem list. Read via ORQQPL LIST; write via
  # BGOPROB SET / BGOPROB DEL; stock VistA write via ORQQPL ADD SAVE /
  # ORQQPL EDIT SAVE; scope via BGOPROB GET CLASS.
  module Problem
    extend self
    extend Shape::Declarable

    # IPL scope codes match the live RPMS IPL UI tabs. The wire codes are
    # best-effort placeholders pending trace capture of BGOPROB GET CLASS
    # parameters; if the codes change, only this table needs updating.
    # "P"-line pieces after the "P" marker for SET^BGOPROB's ARRAY param
    # (BGOPROB.m:218-220; parsed in PROB^BGOPROB — SNOMED CT :246,
    # Descriptive CT :260, Provider text :241, Mapped ICD :240, Location
    # :243, Onset :244, Status :262, Class :245, Problem # :269, Priority
    # :271). The list locks the order so a caller's Hash key insertion
    # order can't reshuffle the payload mid-flight.
    PROB_FIELDS = %i[snomed_ct descriptive_ct description icd_code location_ien
                     onset_date status problem_class problem_number priority].freeze

    # FileMan field number allowed inside a GMPFLD/GMPORIG subscript. FOIA
    # executes each list value as M (`S @ADDARRAY(S)` ORQQPL1.m:160,
    # `S @EDARRAY(S)` ORQQPL1.m:120) with no check, so a subscript that is
    # not this token is refused before any RPC.
    FIELD_NUMBER = /\A(\d+(\.\d+)?|\.\d+)\z/
    CANONICAL_ID = /\A[1-9][0-9]*\z/
    # The only list values the routine is allowed to execute.
    SAFE_ASSIGNMENT = /\A(?:GMPFLD|GMPORIG)\((?:\d+(?:\.\d+)?|\.\d+)\)="(?:[^"[:cntrl:]]|"")*"\z/
    SAFE_COMMENT = /\AGMPFLD\(10,"NEW",[1-9][0-9]*\)="(?:[^"[:cntrl:]]|"")*"\z/

    # List a patient's problems. Underlying RPC: ORQQPL LIST — verified row
    # shape IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^SC^SPEXP^... (see
    # the :problem_list mapping). "No problems" comes back as the sentinel
    # row "^No problems found." (LIST^ORQQPL: ORQQPL.m:17) — no IEN, so it
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

    # Add a problem. The routine requires a resolvable ICD (or a SNOMED CT
    # the site can map — BGOPROB.m:251-252,272-273) and a location IEN
    # (-1049 without one — BGOPROB.m:276).
    def add(dfn, problem)
      raise ArgumentError, "problem must be a Hash" unless problem.is_a?(Hash)
      return failure if invalid_id?(dfn)

      write(dfn, nil, problem)
    end

    def update(dfn, ien, changes)
      raise ArgumentError, "changes must be a Hash" unless changes.is_a?(Hash)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      write(dfn, ien, changes)
    end

    # Logical delete via DEL^BGOPROB (BGOPROB.m:209-211): status "D" plus
    # deletion audit fields. Param: IEN ^ TYPE ^ REASON ^ COMMENT ^ PROB ID.
    def delete(dfn, ien, reason:)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      # Client called directly: DEL returns "" on success, which
      # fetch_scalar would collapse into nil (indistinguishable from
      # broker silence — and silence must never read as a delete).
      raw = RpmsRpc.client.call_rpc(DataMapper.problem_remove.rpc_name, "#{ien}^^#{reason}")
      success = raw.is_a?(String) && !raw.match?(/\A-\d+(?:\.\d+)?\^/)
      { success: success, ien: success ? ien.to_i : nil, raw: raw }
    end

    # ORQQPL stock-VistA reads. Use these when the engine wants the
    # stock-VistA lookup/audit surface rather than the IHS BGOPROB writes
    # above. Returns nil / [] for invalid identifiers without raising; a
    # broker that does not serve the RPC raises RpcNotAvailableError, and one
    # that serves it but not to this user raises RpcRefusedError (#363).

    def lex_search(text)
      return [] if text.to_s.strip.empty?

      Array(DataMapper.problem_lex_search.fetch_many(text.to_s))
    end

    def clinic_search(clinic_ien)
      return [] if invalid_id?(clinic_ien)

      Array(DataMapper.problem_clinic_search.fetch_many(clinic_ien.to_s))
    end

    # Formals: DETAIL(Y,DFN,PROBIEN,ID) (ORQQPL.m:21) — the problem IEN is
    # the third formal, after the patient; ID is declared but never read
    # (ORQQPL.m:21-45). An IEN-only frame put the IEN in DFN and died in M
    # on PROBIEN (#259).
    def details(dfn, ien)
      return nil if invalid_id?(dfn) || invalid_id?(ien)

      DataMapper.problem_detail.fetch_one(dfn.to_s, ien.to_s)
    end

    def audit_history(ien)
      return [] if invalid_id?(ien)

      Array(DataMapper.problem_audit_history.fetch_many(ien.to_s))
    end

    def comments(ien)
      return [] if invalid_id?(ien)

      Array(DataMapper.problem_comments.fetch_many(ien.to_s))
    end

    def init_patient(dfn)
      return nil if invalid_id?(dfn)

      DataMapper.problem_init_patient.fetch_one(dfn.to_s)
    end

    def provider_list(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.problem_provider_list.fetch_many(dfn.to_s))
    end

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

    # ORQQPL stock-VistA state changes beside the IHS BGOPROB API above.
    # inactivate / verify are single-IEN writes. add_stock / update_stock
    # are ORQQPL ADD SAVE / EDIT SAVE and do not replace Problem.add /
    # Problem.update. DELETE, UPDATE, and REPLACE stay on the mappings.

    def inactivate(ien)
      raw = DataMapper.problem_inactivate.fetch_scalar(ien.to_s)
      success_result(raw)
    end

    def verify(ien)
      raw = DataMapper.problem_verify.fetch_scalar(ien.to_s)
      success_result(raw)
    end

    # Stock-VistA add. ORQQPL ADD SAVE -> ADDSAVE^ORQQPL1
    # (ORQQPL1.m:149): four actuals, GMPDFN, GMPROV, GMPVAMC, ADDARRAY.
    # Stock VistA adds a sixth formal GMPSRCH (WorldVistA ORQQPL1.m:191);
    # it is not sent. FOIA runs every list value as M
    # (`S @ADDARRAY(S)`, ORQQPL1.m:160). Lock failure leaves RETURN 0
    # (ORQQPL1.m:154-156). Success stores the new IFN then overwrites
    # RETURN with 1 (ORQQPL1.m:164, :167), so the IFN is not returned.
    def add_stock(dfn, provider_duz:, vamc:, fields:, comments: [])
      patient = canonical_id(dfn)
      provider = canonical_id(provider_duz)
      facility = canonical_id(vamc)
      lines = gmp_lines([ [ "GMPFLD", fields ] ], comments)
      ready = patient && provider && facility && fields.is_a?(Hash) && !fields.empty? &&
        lines.is_a?(Array) && !lines.empty?
      return stock_refused unless ready

      raw = DataMapper.problem_add_save.fetch_scalar(patient, provider, facility, lines)
      stock_save_result(raw)
    end
    shape :add_stock, resource: "problems", verb: "POST", path: "/patients/{dfn}/problems/stock"

    # Stock-VistA edit. ORQQPL EDIT SAVE -> EDSAVE^ORQQPL1
    # (ORQQPL1.m:109): five actuals, GMPIFN, GMPROV, GMPVAMC, UT, EDARRAY.
    # Stock VistA adds GMPSRCH (WorldVistA ORQQPL1.m:118); it is not sent.
    # UT is "1" or "0" (`I UT S GMPLUSER=1`, ORQQPL1.m:115). FOIA runs every
    # list value as M (`S @EDARRAY(S)`, ORQQPL1.m:120). Lock failure sets
    # RETURN 0 (ORQQPL1.m:122-123); the success path sets RETURN 1
    # (ORQQPL1.m:114, :129).
    def update_stock(ien, provider_duz:, vamc:, changes:, originals:, user_type: false, comments: [])
      problem = canonical_id(ien)
      provider = canonical_id(provider_duz)
      facility = canonical_id(vamc)
      flag = case user_type
      when true then "1"
      when false then "0"
      end
      lines = gmp_lines([ [ "GMPFLD", changes ], [ "GMPORIG", originals ] ], comments)
      ready = problem && provider && facility && flag && lines.is_a?(Array) && !lines.empty?
      return stock_refused unless ready

      raw = DataMapper.problem_edit_save.fetch_scalar(problem, provider, facility, flag, lines)
      stock_save_result(raw)
    end
    shape :update_stock, resource: "problems", verb: "PUT", path: "/problems/{ien}/stock"

    private

    # SET^BGOPROB formals after RET: DFN, PRIEN, VIEN, ARRAY, SPEC, PIP
    # (BGOPROB.m:225). SPEC=1 makes the routine take the caller's mapped
    # ICD directly instead of re-deriving it from SNOMED (BGOPROB.m:251) —
    # required for ICD-driven callers that send no SNOMED CT.
    # Success reply is the problem IEN (BGOPROB.m:322); errors -CODE^text.
    def write(dfn, ien, fields)
      raw = DataMapper.problem_set.fetch_scalar(
        dfn.to_s, ien.to_s, "", [ build_p_line(fields) ], "1"
      )

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    def build_p_line(fields)
      ([ "P" ] + PROB_FIELDS.map { |k| fields[k].to_s }).join("^")
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def success_result(raw)
      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      # Stock-VistA convention: leading non-zero IEN OR "1^message" = success.
      success = line.match?(/\A[1-9]\d*\z/) || line.start_with?("1^")
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end

    # Same keys as a non-empty success_result. Exactly "1" is success
    # (ORQQPL1.m:167, :128); "0" and every other reply are not
    # (ORQQPL1.m:156, :123). "0^text" keeps text as the message.
    def stock_save_result(raw)
      line = raw.to_s.strip
      return { success: false, message: nil, raw: raw } if line.empty?

      message = line.sub(/\A[01]\^/, "").strip
      message = nil if message.empty? || line == "1"
      { success: line == "1", message: message, raw: raw }
    end

    def stock_refused
      { success: false, message: nil, raw: nil }
    end

    # Groups are [name, hash] pairs in wire order ("GMPFLD" then "GMPORIG").
    # Returns nil when any input is not a safe literal, so the caller can
    # fail closed before ORQQPL ADD SAVE / EDIT SAVE.
    def gmp_lines(groups, comments)
      return nil unless comments.is_a?(Array)

      lines = []
      groups.each do |name, pairs|
        built = gmp_group(name, pairs)
        return nil unless built

        lines.concat(built)
      end
      comments.each_with_index do |text, index|
        line = gmp_comment(index + 1, text)
        return nil unless line

        lines << line
      end
      return nil unless lines.all? { |line| line.match?(SAFE_ASSIGNMENT) || line.match?(SAFE_COMMENT) }

      lines
    end

    def gmp_group(name, pairs)
      return nil unless pairs.is_a?(Hash) && (name == "GMPFLD" || name == "GMPORIG")

      seen = {}
      lines = []
      pairs.each do |field, value|
        number = fileman_field_number(field)
        quoted = m_quoted(value)
        return nil unless number && quoted && !seen[number]

        seen[number] = true
        lines << "#{name}(#{number})=\"#{quoted}\""
      end
      lines
    end

    # Comment multiple: GMPFLD(10,"NEW",n). n is the 1-based index we
    # assign, never caller text.
    def gmp_comment(index, value)
      quoted = m_quoted(value)
      return nil unless quoted && index.is_a?(Integer) && index.positive?

      "GMPFLD(10,\"NEW\",#{index})=\"#{quoted}\""
    end

    def fileman_field_number(field)
      text = case field
      when String then field
      when Numeric then field.to_s
      end
      return nil if text.nil? || !text.match?(FIELD_NUMBER)

      text
    end

    # String, or Integer via to_s. Embedded quotes are doubled so they stay
    # inside the M literal; a control character would split the line the
    # routine executes, so it is refused.
    def m_quoted(value)
      text = case value
      when String then value
      when Integer then value.to_s
      end
      return nil if text.nil? || !text.valid_encoding? || text.match?(/[[:cntrl:]]/)

      text.gsub('"', '""')
    end

    def canonical_id(value)
      text = case value
      when Integer then value.to_s
      when String then value
      end
      return nil if text.nil? || !text.match?(CANONICAL_ID)

      text
    end
  end
end
