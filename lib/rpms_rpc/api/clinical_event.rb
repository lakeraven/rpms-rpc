# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../fileman_date_parser"

module RpmsRpc
  # Symbolic API for PCE encounter reads (ORWPCE). Reads only.
  #
  # These methods do not guard cross-patient access on the note path. When
  # the note IEN is a positive integer, ORWPCE GET VISIT, ORWPCE HASVISIT,
  # and ORWPCE PCE4NOTE take the visit from ^TIU(8925,note,0) and ignore
  # DFN (GETVISIT^ORWPCE2, ORWPCE2.m:64-67; HASVISIT^ORWPCE,
  # ORWPCE.m:118-123; PCE4NOTE^ORWPCE3, ORWPCE3.m:9-17). Optional
  # visit_string, location IEN, and datetime on that path are sent only
  # when blank or well-formed; a malformed value makes no call. A note IEN
  # of 0 looks the visit up by DFN instead: GET VISIT and PCE4NOTE use the
  # visit string (location;FileMan datetime;service category); HASVISIT
  # uses the location IEN and the FileMan datetime.
  #
  # HASVISIT^ORWPCE answers -1 when there is no visit, 0 for a stand-alone
  # visit, and 1 when that visit is tied to an appointment
  # ($$VST2APPT^PXAPI via VST2APPT^PXUTL1, PXUTL1.m:65-78). -1 and an empty
  # reply are not found, never data.
  module ClinicalEvent
    extend self
    extend Shape::Declarable

    # Visit IEN for a note, or nil when the broker reports none (-1 or an
    # empty reply) or the arguments cannot name a visit.
    def visit_for_note(note_ien, dfn, visit_string = "")
      return nil unless note_lookup?(note_ien, dfn, visit_string)
      return nil unless rpc_served?(DataMapper.pce_get_visit)

      DataMapper.pce_get_visit.fetch_scalar(note_ien, dfn, visit_string)
    end
    shape :visit_for_note, resource: "clinical-events", verb: "GET",
          path: "/progress-notes/{note_ien}/clinical-events/patients/{dfn}/visit"

    # True when HASVISIT reports a visit (0 stand-alone, 1 appointment).
    # False when the reply is -1 or empty, or when no call is made.
    def has_visit?(note_ien, dfn, location_ien = "", datetime = "")
      return false unless hasvisit_args?(note_ien, dfn, location_ien, datetime)
      return false unless rpc_served?(DataMapper.pce_has_visit)

      DataMapper.pce_has_visit.fetch_scalar(note_ien, dfn, location_ien, datetime) == true
    end
    shape :has_visit?, resource: "clinical-events", verb: "GET",
          path: "/progress-notes/{note_ien}/clinical-events/patients/{dfn}/has-visit"

    # :none, :stand_alone, or :appointment. Nil when no call is made.
    def visit_status(note_ien, dfn, location_ien = "", datetime = "")
      return nil unless hasvisit_args?(note_ien, dfn, location_ien, datetime)
      return nil unless rpc_served?(DataMapper.pce_has_visit)

      raw = RpmsRpc.client.call_rpc(
        DataMapper.pce_has_visit.rpc_name, note_ien, dfn, location_ien, datetime
      )
      DataMapper.pce_has_visit.parse_hasvisit_status(raw)
    end
    shape :visit_status, resource: "clinical-events", verb: "GET",
          path: "/progress-notes/{note_ien}/clinical-events/patients/{dfn}/visit-status"

    # { location_ien:, datetime_raw:, service_category: } for a note, or nil
    # when the note has no visit string.
    def note_visit_string(note_ien)
      return nil unless positive_id?(note_ien)
      return nil unless rpc_served?(DataMapper.pce_note_visit_string)

      DataMapper.pce_note_visit_string.fetch_scalar(note_ien)
    end
    shape :note_visit_string, resource: "clinical-events", verb: "GET",
          path: "/progress-notes/{note_ien}/clinical-events/note-visit-string"

    # The PCE4NOTE bundle (header, visit, providers, diagnoses, procedures,
    # immunizations, patient_education, exams, comments, opaque_records),
    # or nil when the reply is -1 or empty.
    def pce_for_note(note_ien, dfn, visit_string = "")
      return nil unless note_lookup?(note_ien, dfn, visit_string)
      return nil unless rpc_served?(DataMapper.pce_for_note)

      raw = RpmsRpc.client.call_rpc(DataMapper.pce_for_note.rpc_name, note_ien, dfn, visit_string)
      lines = raw.is_a?(Array) ? raw : raw.to_s.split(/\r\n|\r|\n/, -1)
      DataMapper.pce_for_note.parse_note_bundle(lines)
    end
    shape :pce_for_note, resource: "clinical-events", verb: "GET",
          path: "/progress-notes/{note_ien}/clinical-events/patients/{dfn}/pce"

    # Active immunizations (IEN and name). +date+ is a FileMan date the
    # routine receives as ORDT. Omitted, the call sends no parameter; a
    # blank string is sent empty. A value that is not a FileMan date makes
    # no call and returns [].
    def immunization_types(date = nil)
      listed(DataMapper.pce_immunization_types, date)
    end
    shape :immunization_types, resource: "clinical-events", verb: "GET",
          path: "/clinical-events/immunization-types"

    # Active skin tests (IEN and name). +date+ is the same optional ORDT:
    # omitted sends no parameter, blank sends "", and a non-FileMan date
    # makes no call and returns [].
    def skin_test_types(date = nil)
      listed(DataMapper.pce_skin_test_types, date)
    end
    shape :skin_test_types, resource: "clinical-events", verb: "GET",
          path: "/clinical-events/skin-test-types"

    def exam_types
      listed(DataMapper.pce_exam_types)
    end
    shape :exam_types, resource: "clinical-events", verb: "GET",
          path: "/clinical-events/exam-types"

    def education_topics
      listed(DataMapper.pce_education_topics)
    end
    shape :education_topics, resource: "clinical-events", verb: "GET",
          path: "/clinical-events/education-topics"

    # Active health factors. Category and category IEN are present only
    # when +add_categories+ is true (HFTYPE^ORWPCE2 sends ADDCATS = 1).
    def health_factor_types(add_categories: false)
      return [] unless rpc_served?(DataMapper.pce_health_factor_types)

      if add_categories
        DataMapper.pce_health_factor_types.fetch_many("1")
      else
        DataMapper.pce_health_factor_types.fetch_many
      end
    end
    shape :health_factor_types, resource: "clinical-events", verb: "GET",
          path: "/clinical-events/health-factor-types"

    private

    def listed(mapping, date = nil)
      return [] unless optional_fileman_date?(date)
      return [] unless rpc_served?(mapping)

      date.nil? ? mapping.fetch_many : mapping.fetch_many(date)
    end

    # A positive note reads the visit off the TIU document. Note 0 is the
    # location lookup, and only when the visit string names a location and
    # a FileMan datetime. Either way the patient id has to be a positive
    # integer; the note path does not compare it to the note. On the
    # positive-note path an optional visit string is sent only when blank
    # or well-formed.
    def note_lookup?(note_ien, dfn, visit_string)
      return false unless positive_id?(dfn)
      if positive_id?(note_ien)
        return blank_param?(visit_string) || visit_string_lookup?(visit_string)
      end
      return false unless zero_id?(note_ien)

      visit_string_lookup?(visit_string)
    end

    # On the positive-note path each of location and datetime is sent only
    # when blank or well-formed. Note 0 still requires both.
    def hasvisit_args?(note_ien, dfn, location_ien, datetime)
      return false unless positive_id?(dfn)
      if positive_id?(note_ien)
        return optional_location?(location_ien) && optional_fileman_datetime?(datetime)
      end
      return false unless zero_id?(note_ien)

      positive_id?(location_ien) && fileman_datetime?(datetime)
    end

    def optional_location?(location_ien)
      blank_param?(location_ien) || positive_id?(location_ien)
    end

    def optional_fileman_datetime?(datetime)
      blank_param?(datetime) || fileman_datetime?(datetime)
    end

    # nil omits the parameter, "" is sent, and any other value must be a
    # FileMan date (or datetime).
    def optional_fileman_date?(date)
      blank_param?(date) || fileman_datetime?(date)
    end

    def blank_param?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end

    def visit_string_lookup?(visit_string)
      location, datetime, = visit_string.to_s.split(";", 3)
      positive_id?(location) && fileman_datetime?(datetime)
    end

    def fileman_datetime?(value)
      value.is_a?(String) && !value.empty? && !FilemanDateParser.parse_datetime_or_date(value).nil?
    end

    # Same question Compatibility asks the broker. A client that cannot
    # answer (MockClient, or Client#served_rpcs) is not a miss: the RPC
    # call still runs, and a server that does not serve it raises on that
    # call. A client that answers and omits the name makes no call.
    def rpc_served?(mapping)
      client = RpmsRpc.client
      return true unless client.respond_to?(:served_rpcs)

      client.served_rpcs([ mapping.rpc_name ]).include?(mapping.rpc_name)
    rescue Error
      true
    end

    def positive_id?(value)
      text = digit_text(value)
      !text.nil? && text.to_i.positive?
    end

    def zero_id?(value)
      text = digit_text(value)
      !text.nil? && text.to_i.zero?
    end

    # A non-negative integer, as an Integer or a digit-only String.
    # "3.5", " 3", and "" are not ids; nothing is sent for them.
    def digit_text(value)
      text = value.is_a?(Integer) ? value.to_s : value
      return unless text.is_a?(String) && text.match?(/\A\d+\z/)

      text
    end
  end
end
