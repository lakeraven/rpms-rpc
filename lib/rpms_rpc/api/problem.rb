# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the problem list. Read via ORQQPL LIST; write/scope via
  # BGOPROB1 EDPROB and BGOPROB GET CLASS.
  module Problem
    extend self

    # IPL scope codes match the live RPMS IPL UI tabs. The wire codes are
    # best-effort placeholders pending trace capture of BGOPROB GET CLASS
    # parameters; if the codes change, only this table needs updating.
    SCOPE_CODES = {
      core: "C",
      episodic: "E",
      routine_admin: "R",
      inactive: "I"
    }.freeze

    EDIT_ACTIONS = {
      add: "A",
      update: "E",
      delete: "D"
    }.freeze

    # Wire field order for BGOPROB1 EDPROB. Field positions are best-effort
    # pending wider trace capture; this list locks the order so a caller's
    # Hash key insertion order can't reshuffle the payload mid-flight.
    EDPROB_FIELDS = %i[icd_code description status onset_date provider_duz reason].freeze

    def for_patient(dfn)
      DataMapper.problem_list.fetch_many(dfn.to_s)
    end

    def add(dfn, problem)
      raise ArgumentError, "problem must be a Hash" unless problem.is_a?(Hash)
      return failure if invalid_id?(dfn)

      write(dfn, EDIT_ACTIONS[:add], nil, problem)
    end

    def update(dfn, ien, changes)
      raise ArgumentError, "changes must be a Hash" unless changes.is_a?(Hash)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      write(dfn, EDIT_ACTIONS[:update], ien, changes)
    end

    def delete(dfn, ien, reason:)
      return failure if invalid_id?(dfn) || invalid_id?(ien)

      write(dfn, EDIT_ACTIONS[:delete], ien, { reason: reason })
    end

    def filter(dfn, scope:)
      return [] if invalid_id?(dfn)

      code = SCOPE_CODES[scope]
      raise ArgumentError, "unknown scope: #{scope.inspect}" if code.nil?

      Array(DataMapper.problem_filter.fetch_many(dfn.to_s, code))
    end

    # ORQQPL stock-VistA reads. Use these when the engine wants the
    # stock-VistA lookup/audit surface rather than the IHS BGOPROB writes
    # above. Returns nil / [] for invalid identifiers without raising.

    def lex_search(text)
      return [] if text.to_s.strip.empty?
      return unsupported_list unless workflow_supported?

      Array(DataMapper.problem_lex_search.fetch_many(text.to_s))
    end

    def clinic_search(clinic_ien)
      return [] if invalid_id?(clinic_ien)
      return unsupported_list unless workflow_supported?

      Array(DataMapper.problem_clinic_search.fetch_many(clinic_ien.to_s))
    end

    def details(ien)
      return nil if invalid_id?(ien)
      return unsupported_detail unless workflow_supported?

      DataMapper.problem_detail.fetch_one(ien.to_s)
    end

    def audit_history(ien)
      return [] if invalid_id?(ien)
      return unsupported_list unless workflow_supported?

      Array(DataMapper.problem_audit_history.fetch_many(ien.to_s))
    end

    def comments(ien)
      return [] if invalid_id?(ien)
      return unsupported_list unless workflow_supported?

      Array(DataMapper.problem_comments.fetch_many(ien.to_s))
    end

    def init_patient(dfn)
      return nil if invalid_id?(dfn)
      return unsupported_detail unless workflow_supported?

      DataMapper.problem_init_patient.fetch_one(dfn.to_s)
    end

    def provider_list(dfn)
      return [] if invalid_id?(dfn)
      return unsupported_list unless workflow_supported?

      Array(DataMapper.problem_provider_list.fetch_many(dfn.to_s))
    end

    def edit_load(ien)
      return nil if invalid_id?(ien)
      return unsupported_detail unless workflow_supported?

      DataMapper.problem_edit_load.fetch_one(ien.to_s)
    end

    # ORQQPL stock-VistA state-change writes that don't overlap with the
    # IHS BGOPROB API above. Inactivate and verify are clean adds; ADD
    # SAVE / EDIT SAVE / DELETE / UPDATE / REPLACE are wired in mappings.rb
    # for direct DataMapper use but not given Ruby-side wrappers here
    # because they shadow the existing add/update/delete methods.

    def inactivate(ien)
      return unsupported_result unless workflow_supported?

      raw = DataMapper.problem_inactivate.fetch_scalar(ien.to_s)
      success_result(raw)
    end

    def verify(ien)
      return unsupported_result unless workflow_supported?

      raw = DataMapper.problem_verify.fetch_scalar(ien.to_s)
      success_result(raw)
    end

    private

    def write(dfn, action, ien, fields)
      payload = build_payload(action, ien, fields)
      raw = DataMapper.problem_edit.fetch_scalar(dfn.to_s, payload)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    def build_payload(action, ien, fields)
      pieces = [ action, ien.to_s ]
      pieces.concat(EDPROB_FIELDS.map { |k| fields[k].to_s })
      pieces.join("^")
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def workflow_supported?
      RpmsRpc.client.supports?(:orqqpl_problem_workflow)
    rescue NotConfiguredError
      false
    end

    def unsupported_list
      []
    end

    def unsupported_detail
      nil
    end

    def unsupported_result
      { success: false, error: "ORQQPL problem workflow not available on this server", raw: nil }
    end

    def success_result(raw)
      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      # Stock-VistA convention: leading non-zero IEN OR "1^message" = success.
      success = line.match?(/\A[1-9]\d*\z/) || line.start_with?("1^")
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end
  end
end
