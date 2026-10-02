# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for RPMS Health Summary reports and clinical reminders.
  # Underlying RPCs: ORWRP REPORT TEXT, ORQQPX REMINDERS LIST, ORQQPX
  # REMINDER DETAIL.
  #
  # The report-type reads (`types`, `type_components`) and the GMTS reads
  # (`personal_wellness_report`, `flowsheet_definitions`, `flowsheet`,
  # `health_maintenance`) this module once offered sent ORWRP TYPES /
  # TYPE COMPONENTS and GMTS * names no built 9.0 image registers; they
  # were removed (#207). The registered health-summary surface is
  # ORWRP2 HS * (component lists, report text); model it from the routines
  # before adding those reads back (ADR 0003).
  module HealthSummary
    extend self

    COMPONENT_TYPES = {
      demographics: "DEM",
      problems: "PRB",
      allergies: "ALL",
      medications: "MED",
      immunizations: "IMM",
      vitals: "VIT",
      labs: "LAB",
      radiology: "RAD",
      appointments: "APT",
      clinical_reminders: "REM",
      health_factors: "HF",
      education: "EDU",
      procedures: "PRC"
    }.freeze

    # The summary types `for_patient` resolves `summary_type:` against. A
    # static list: no registered RPC lists the HEALTH SUMMARY TYPE file
    # (#142) this way, so the IENs here are assumptions the caller can
    # override by passing a type name that is in the list.
    DEFAULT_TYPES = [
      { ien: 1, name: "STANDARD", description: "Standard Health Summary", owner: nil },
      { ien: 2, name: "BRIEF", description: "Brief Summary", owner: nil },
      { ien: 3, name: "COMPREHENSIVE", description: "Comprehensive Summary", owner: nil },
      { ien: 4, name: "PATIENT", description: "Patient-Facing Summary", owner: nil }
    ].freeze

    def for_patient(dfn, summary_type: "STANDARD")
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      resolved = resolve_summary_type(summary_type)
      text = DataMapper.report_text.fetch_text("#{dfn}^#{resolved[:ien]}^")
      # Report the resolved type name (which may differ from the caller's input
      # when the input was unknown and we fell back to the first available type).
      parse_health_summary(text, resolved[:name])
    end

    def generate_selective(dfn, components:)
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      {
        patient_dfn: dfn,
        generated_at: Time.now,
        sections: Array(components).filter_map { |component| component_data(dfn, component) },
        type: "SELECTIVE"
      }
    end

    def component_data(dfn, component)
      return nil if invalid_id?(dfn) || component.nil?

      sym = component.respond_to?(:to_sym) ? component.to_sym : nil
      code = sym && COMPONENT_TYPES[sym]
      return nil if code.nil?

      text = DataMapper.report_text.fetch_text("#{dfn}^^#{code}")
      return nil if blank?(text)

      {
        name: titleize(component.to_s),
        code: code,
        content: text,
        generated_at: Time.now
      }
    end

    def clinical_reminders(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.reminders_list.fetch_many(dfn.to_s)
    end

    def reminder_detail(dfn, reminder_ien)
      return nil if invalid_id?(dfn) || invalid_id?(reminder_ien)

      text = DataMapper.reminder_detail.fetch_text("#{dfn}^#{reminder_ien}")
      blank?(text) ? nil : { content: text, parsed_at: Time.now }
    end

    private

    # Resolve a caller-supplied summary type to the entry of DEFAULT_TYPES
    # that will be used; an unrecognised name falls back to the first type,
    # so callers see the resolved name rather than their input.
    def resolve_summary_type(type_name)
      match = DEFAULT_TYPES.find { |type| type[:name].to_s.upcase == type_name.to_s.upcase }
      return { ien: match[:ien], name: match[:name] } if match

      fallback = DEFAULT_TYPES.first
      { ien: fallback[:ien], name: fallback[:name] }
    end

    def parse_health_summary(text, type)
      return error_summary("No data returned") if blank?(text)

      sections = []
      current = nil

      text.to_s.split(/\r?\n/).each do |line|
        stripped = line.strip

        if section_header?(stripped)
          # Separator-only lines (just dashes / equals / asterisks) start a
          # header context but contribute no content. Match the gateway by
          # skipping them entirely.
          next if stripped.match?(/^[-=*]+$/)

          sections << current if current && !blank?(current[:content])

          # Gateway strips ALL punctuation in [-*:=] from the line and uses the
          # remainder as the section name. So "PATIENT: Test Patient" becomes
          # the name "PATIENT Test Patient" with no inline content split.
          section_name = stripped.gsub(/[-*:=]+/, "").strip
          current = { name: titleize(section_name), content: "" }
        elsif current
          current[:content] += "#{line}\n"
        else
          current = { name: "Summary", content: "#{line}\n" }
        end
      end

      sections << current if current && !blank?(current[:content])
      { type: type, generated_at: Time.now, sections: sections, raw_content: text }
    end

    # Gateway recognises four header forms: ALL-CAPS-WITH-COLON, and lines of
    # dashes / equals / asterisks (3+).
    def section_header?(stripped)
      stripped.match?(/^[A-Z]{3,}:/) ||
        stripped.match?(/^-{3,}$/) ||
        stripped.match?(/^={3,}$/) ||
        stripped.match?(/^\*{3,}$/)
    end

    def error_summary(message)
      { type: "ERROR", generated_at: Time.now, sections: [], error: message }
    end

    def titleize(value)
      value.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
