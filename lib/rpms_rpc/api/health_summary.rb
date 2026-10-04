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

    # The Health Summary entry of the OE/RR REPORT file (#101.24): ORWRP
    # REPORT LISTS lists it as "1^Health Summary^...^HS^ORWRP1^...^ORWRP
    # REPORT TEXT", and RPT^ORWRP resolves RPTID against that file's ID
    # field (ORWRP.m:103-107) before dispatching to HS^ORWRP1.
    HEALTH_SUMMARY_REPORT_ID = "1"

    def for_patient(dfn, summary_type: "STANDARD")
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      resolved = resolve_summary_type(summary_type)
      text = report_text(dfn, HEALTH_SUMMARY_REPORT_ID, hs_type: resolved[:ien])
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

      # ORWRP REPORT TEXT has no component selector for the Health Summary
      # report: HS^ORWRP1 runs the whole summary type (ORWRP1.m:12-28), and
      # the "~component" suffix of RPTID feeds only the listview reports
      # (ORWRP.m:91,103,124). So the summary is fetched whole and the
      # component's section picked out of it here.
      summary = for_patient(dfn)
      name = titleize(component.to_s)
      section = summary[:sections].find { |s| s[:name].casecmp?(name) }
      return nil if section.nil? || blank?(section[:content])

      {
        name: name,
        code: code,
        content: section[:content],
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

    # Formals: RPT(ROOT,DFN,RPTID,HSTYPE,DTRANGE,EXAMID,ALPHA,OMEGA)
    # (ORWRP.m:88-96). RPTID is read unconditionally (ORWRP.m:102-103);
    # the rest are $G'd: HSTYPE is merged into the report id when given
    # (:124), DTRANGE is days back from today (:121), EXAMID a radiology
    # exam (:125), ALPHA/OMEGA a FileMan date range (:113-122). Every
    # formal goes over the wire, empty when unused. The old single
    # "DFN^type^" parameter left RPTID undefined and the call died in M
    # (#259).
    def report_text(dfn, report_id, hs_type: "", days_back: "", exam_id: "", from: "", to: "")
      DataMapper.report_text.fetch_text(dfn.to_s, report_id.to_s, hs_type.to_s, days_back.to_s,
                                        exam_id.to_s, from.to_s, to.to_s)
    end

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
