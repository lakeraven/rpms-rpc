# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the ORWPCE PCE V-file surface. Engine-facing subset
  # of the broader ORWPCE namespace — covers visit lookup, type-table
  # reads (exam / health-factor / immunization / skin-test / treatment /
  # education / set-of-codes), V-file writes (SAVE / DELETE / FORCE),
  # and encounter wiring (ASKPCE / ANYTIME / PCE4NOTE / NOTEVSTR) for
  # note ↔ visit binding.
  #
  # Separated from RpmsRpc::Procedure / RpmsRpc::Device (also ORWPCE)
  # because the V-file event surface is its own contract — wraps and
  # gating differ. Probed via :orwpce_pce_workflow capability
  # (read-only ORWPCE GET VISIT).
  #
  # Companion to RpmsRpc::Encounter — Encounter#open hydrates the BEHOENCX
  # IHS visit context; ClinicalEvent operates on the stock-VistA PCE
  # event surface inside that visit.
  module ClinicalEvent
    extend self

    # -- Reads -------------------------------------------------------------

    def get_visit(visit_ien)
      return nil if invalid_id?(visit_ien)
      return nil unless workflow_supported?

      DataMapper.pce_get_visit.fetch_one(visit_ien.to_s)
    end

    def exam_types
      return [] unless workflow_supported?

      Array(DataMapper.pce_exam_types.fetch_many)
    end

    def health_factor_types
      return [] unless workflow_supported?

      Array(DataMapper.pce_health_factor_types.fetch_many)
    end

    def immunization_types
      return [] unless workflow_supported?

      Array(DataMapper.pce_immunization_types.fetch_many)
    end

    def skin_test_types
      return [] unless workflow_supported?

      Array(DataMapper.pce_skin_test_types.fetch_many)
    end

    def treatment_types
      return [] unless workflow_supported?

      Array(DataMapper.pce_treatment_types.fetch_many)
    end

    def education_topics
      return [] unless workflow_supported?

      Array(DataMapper.pce_education_topics.fetch_many)
    end

    def set_of_codes(set_name)
      return [] if set_name.to_s.strip.empty?
      return [] unless workflow_supported?

      Array(DataMapper.pce_set_of_codes.fetch_many(set_name.to_s))
    end

    def excluded
      return [] unless workflow_supported?

      Array(DataMapper.pce_excluded.fetch_many)
    end

    def active_codes
      return [] unless workflow_supported?

      Array(DataMapper.pce_active_codes.fetch_many)
    end

    def active_providers
      return [] unless workflow_supported?

      Array(DataMapper.pce_active_providers.fetch_many)
    end

    def active_problems(dfn)
      return [] if invalid_id?(dfn)
      return [] unless workflow_supported?

      Array(DataMapper.pce_active_problems.fetch_many(dfn.to_s))
    end

    # -- Writes ------------------------------------------------------------

    def save(visit_ien, payload)
      return validation_error("invalid visit_ien") if invalid_id?(visit_ien)
      return validation_error("payload required") if payload.to_s.strip.empty?
      return unsupported_result unless workflow_supported?

      raw = DataMapper.pce_save.fetch_scalar(visit_ien.to_s, payload.to_s)
      success_result(raw)
    end

    def delete(visit_ien, event_ien)
      return validation_error("invalid visit_ien") if invalid_id?(visit_ien)
      return validation_error("invalid event_ien") if invalid_id?(event_ien)
      return unsupported_result unless workflow_supported?

      raw = DataMapper.pce_delete.fetch_scalar(visit_ien.to_s, event_ien.to_s)
      success_result(raw)
    end

    def force(visit_ien)
      return validation_error("invalid visit_ien") if invalid_id?(visit_ien)
      return unsupported_result unless workflow_supported?

      raw = DataMapper.pce_force.fetch_scalar(visit_ien.to_s)
      success_result(raw)
    end

    # -- Encounter wiring --------------------------------------------------

    def ask_pce(visit_ien)
      return nil if invalid_id?(visit_ien)
      return nil unless workflow_supported?

      DataMapper.pce_ask_pce.fetch_scalar(visit_ien.to_s)
    end

    def anytime
      return nil unless workflow_supported?

      DataMapper.pce_anytime.fetch_scalar
    end

    def for_note(note_ien)
      return [] if invalid_id?(note_ien)
      return [] unless workflow_supported?

      Array(DataMapper.pce_for_note.fetch_many(note_ien.to_s))
    end

    def note_visit_string(note_ien)
      return nil if invalid_id?(note_ien)
      return nil unless workflow_supported?

      DataMapper.pce_note_visit_string.fetch_scalar(note_ien.to_s)
    end

    private

    def workflow_supported?
      RpmsRpc.client.supports?(:orwpce_pce_workflow)
    rescue NotConfiguredError
      false
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def unsupported_result
      { success: false, error: "ORWPCE PCE workflow not available on this server", raw: nil }
    end

    def validation_error(reason)
      { success: false, error: reason, raw: nil }
    end

    def success_result(raw)
      line = raw.to_s.strip
      return { success: false, raw: raw } if line.empty?

      # Stock-VistA convention: leading non-zero IEN or "1^message" = success.
      # Mirrors PR #157 lesson — only strip status flag when followed by ^.
      success = line.match?(/\A[1-9]\d*\z/) || line.start_with?("1^")
      message = line.sub(/\A[01]\^/, "").strip
      { success: success, message: message.empty? ? nil : message, raw: raw }
    end
  end
end
