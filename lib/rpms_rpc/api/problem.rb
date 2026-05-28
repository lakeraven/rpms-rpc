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

    def for_patient(dfn)
      DataMapper.problem_list.fetch_many(dfn.to_s)
    end

    def add(dfn, problem)
      raise ArgumentError, "problem is required" if problem.nil? || !problem.is_a?(Hash)
      return failure if invalid_id?(dfn)

      write(dfn, EDIT_ACTIONS[:add], nil, problem)
    end

    def update(dfn, ien, changes)
      raise ArgumentError, "changes is required" if changes.nil? || !changes.is_a?(Hash)
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
      pieces.concat(fields.values.map(&:to_s))
      pieces.join("^")
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
