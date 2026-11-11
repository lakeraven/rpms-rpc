# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "ddr_fileman"

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
    extend Shape::Declarable

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

    # The IHS Health Summary report: the OE/RR REPORT entry (#101.24) whose
    # ID is "IHS" runs HS^ORWRPBHS, which prints the IHS HEALTH SUMMARY TYPE
    # (#9001015) it is sent as HSTYPE (ORWRPBHS.m:5-17). RPT^ORWRP finds the
    # entry by that ID (ORWRP.m:103-107). Report ID 1 runs HS^ORWRP1 instead,
    # which reads HSTYPE as a VA type (#142): an IHS type IEN sent there
    # prints whichever VA type has that IEN, or faults (#662).
    HEALTH_SUMMARY_REPORT_ID = "IHS"

    # The IHS type for adults that IHS distributes to every site (APCHZMGR).
    DEFAULT_SUMMARY_TYPE = "ADULT REGULAR"

    # What HSX^ORWRPBHS prints in place of the summary when generating it
    # faults (ORWRPBHS.m:19-22).
    REPORT_FAULT = "An error was encountered generating this report."

    # The IHS HEALTH SUMMARY TYPE file (#9001015), whose IEN HS^ORWRPBHS
    # takes as HSTYPE.
    SUMMARY_TYPE_FILE = "9001015"

    # The IHS health summary types on file, by name:
    # [{ ien: "7", name: "ADULT REGULAR" }, ...], read through DDR LISTER on
    # #9001015's B index. nil when the list cannot be read whole.
    def summary_types
      listed = DdrFileman.lister(file: SUMMARY_TYPE_FILE, fields: "@;.01", flags: "IP", xref: "B")
      return nil if listed.nil? || listed[:error] || !listed[:data] || listed[:more]

      listed[:entries].map { |entry| { ien: entry[:ien].to_s, name: entry[:pieces].first.to_s } }
    end
    shape :summary_types, resource: "health-summaries", verb: "GET", path: "/health-summaries/summary-types"

    # The patient's IHS health summary of `summary_type`, a type name from
    # {summary_types} (any case) or its IEN. A type that is not on file
    # sends no report and answers an error summary that names it.
    def for_patient(dfn, summary_type: DEFAULT_SUMMARY_TYPE)
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      types = summary_types
      return error_summary("Could not read the health summary types") if types.nil?

      resolved = resolve_summary_type(types, summary_type)
      return error_summary("Unknown health summary type: #{summary_type}") if resolved.nil?

      text = report_text(dfn, HEALTH_SUMMARY_REPORT_ID, hs_type: resolved[:ien])
      parse_health_summary(text, resolved[:name])
    end
    shape :for_patient, resource: "health-summaries", verb: "GET", path: "/patients/{dfn}/health-summaries"

    def generate_selective(dfn, components:)
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      {
        patient_dfn: dfn,
        generated_at: Time.now,
        sections: Array(components).filter_map { |component| component_data(dfn, component) },
        type: "SELECTIVE"
      }
    end
    shape :generate_selective, resource: "health-summaries", verb: "POST", path: "/patients/{dfn}/health-summaries/generate-selective"

    def component_data(dfn, component)
      return nil if invalid_id?(dfn) || component.nil?

      sym = component.respond_to?(:to_sym) ? component.to_sym : nil
      code = sym && COMPONENT_TYPES[sym]
      return nil if code.nil?

      # ORWRP REPORT TEXT has no component selector for the Health Summary
      # report: HS^ORWRPBHS prints the whole summary type (ORWRPBHS.m:5-17),
      # and the "~component" suffix of RPTID feeds only the listview reports
      # (ORWRP.m:91,103,124). So the summary is fetched whole and the
      # component's section picked out of it here: the first section whose
      # banner is one of the component's headings (COMPONENT_HEADINGS).
      summary = for_patient(dfn)
      name = titleize(component.to_s)
      section = summary[:sections].find { |s| component_section?(s[:name], sym) }
      return nil if section.nil? || blank?(section[:content])

      {
        name: name,
        code: code,
        content: section[:content],
        generated_at: Time.now
      }
    end
    shape :component_data, resource: "health-summaries", verb: "GET", path: "/patients/{dfn}/health-summaries/component-data"

    def clinical_reminders(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.reminders_list.fetch_many(dfn.to_s)
    end
    shape :clinical_reminders, resource: "health-summaries", verb: "GET", path: "/patients/{dfn}/health-summaries/clinical-reminders"

    # REMDET(ORY,ORPT,ORIEN)^ORQQPX (ORQQPX.m:51) takes the DFN and the
    # reminder (#811.9) IEN as two formals. Sent as one "DFN^IEN" parameter,
    # ORIEN is undefined and the call dies (LVUNDEF at REMDET+5, #694).
    def reminder_detail(dfn, reminder_ien)
      return nil if invalid_id?(dfn) || invalid_id?(reminder_ien)

      text = DataMapper.reminder_detail.fetch_text(dfn.to_s, reminder_ien.to_s)
      blank?(text) ? nil : { content: text, parsed_at: Time.now }
    end
    shape :reminder_detail, resource: "health-summaries", verb: "GET", path: "/patients/{dfn}/health-summaries/reminders/{reminder_ien}"

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

    # The listed type that a caller's name (any case) or IEN names, or nil.
    def resolve_summary_type(types, wanted)
      text = wanted.to_s.strip
      return nil if text.empty?

      types.find { |type| text.match?(/\A\d+\z/) ? type[:ien] == text : type[:name].casecmp?(text) }
    end

    # HSX^ORWRPBHS prints the summary in pages, 80 columns wide (APCHS0,
    # through CAPTURE^CIAUHFS at width 80). Each page opens with HEADER^APCHS0:
    # the confidentiality line, then the patient, type and page number, each
    # centred between runs of asterisks; the report closes with "*** END *".
    # Each section opens with BREAK^APCHS0: the component's heading and any
    # "(max ...)" note, centred between equal runs of dashes, which repeats at
    # the top of the next page when the section runs on. A run is
    # (80-3-length)/2-1 whole characters long (BREAK+2^APCHS0), and a line is a
    # banner only when its runs are exactly that long. A heading of 74 or
    # more characters has none: " SCHEDULED ENCOUNTERS (...) (max 10 visits or
    # 90 days) ", one space either side. A page's patient line can lose its
    # asterisks the same way, so the line after the confidentiality line is
    # dropped whatever it holds.
    PAGE_BANNER = /\A\*{3,} .*\*{3,}\z/
    CONFIDENTIALITY_LINE = "CONFIDENTIAL PATIENT INFORMATION"
    SECTION_BANNER = /\A(-*) (\S.*\S) \1\z/
    REPORT_WIDTH = 80
    private_constant :PAGE_BANNER, :CONFIDENTIALITY_LINE, :SECTION_BANNER, :REPORT_WIDTH

    # The heading words each component's sections print under, as the IHS
    # summary types on the pinned build print them, less "(...)" notes. A
    # section belongs to a component when its heading is one of these or
    # ends with one ("PCC ACTIVE PROBLEMS", "MOST RECENT PATIENT EDUCATION").
    # A component not listed matches its own name ("LABS").
    COMPONENT_HEADINGS = {
      demographics: [ "DEMOGRAPHIC DATA", "BRIEF DEMOGRAPHICS" ],
      problems: [ "ACTIVE PROBLEMS" ],
      allergies: [ "ALLERGIES", "ALLERGIES/ADVERSE REACTIONS", "ALLERG" ],
      medications: [ "CURRENT MEDICATIONS", "ALL MEDICATIONS" ],
      immunizations: [ "IMMUNIZATIONS" ],
      vitals: [ "MEASUREMENT PANELS", "MEASUREMENTS TAKEN" ],
      appointments: [ "SCHEDULED ENCOUNTERS", "SCHEDULED APPOINTMENTS", "FUTURE APPOINTMENTS" ],
      clinical_reminders: [ "HEALTH MAINTENANCE REMINDERS" ],
      health_factors: [ "HEALTH FACTORS" ],
      education: [ "PATIENT EDUCATION" ]
    }.freeze
    private_constant :COMPONENT_HEADINGS

    # { type:, generated_at:, sections: [{ name:, content: }], raw_content: }.
    # A section's name is its banner's text as the server printed it. Page
    # banners are dropped, and a section that runs onto the next page is
    # kept as one. A report that faulted (REPORT_FAULT) is an error summary.
    def parse_health_summary(text, type)
      return error_summary("No data returned") if blank?(text)
      return error_summary("The server could not generate the #{type} health summary") if text.lstrip.start_with?(REPORT_FAULT)

      sections = []
      after_confidentiality = false
      text.to_s.split(/\r?\n/).each do |line|
        next after_confidentiality = false if after_confidentiality
        next after_confidentiality = line.include?(CONFIDENTIALITY_LINE) if line.match?(PAGE_BANNER)

        if (banner = section_banner(line))
          sections << { name: banner, content: +"" } unless sections.last&.fetch(:name) == banner
        elsif sections.any?
          sections.last[:content] << "#{line.rstrip}\n"
        elsif !blank?(line)
          sections << { name: "Summary", content: +"#{line.rstrip}\n" }
        end
      end

      { type: type, generated_at: Time.now, sections: sections.reject { |s| blank?(s[:content]) }, raw_content: text }
    end

    # The heading a BREAK^APCHS0 banner line prints, or nil.
    def section_banner(line)
      match = line.match(SECTION_BANNER)
      return nil if match.nil?
      return nil unless match[1].length == [ ((REPORT_WIDTH - 3 - match[2].length) / 2) - 1, 0 ].max

      match[2]
    end

    # A section banner names a component when, less its "(...)" notes, it is
    # one of the component's headings or ends with one, in any case.
    def component_section?(banner, component)
      words = banner.gsub(/\s*\([^)]*\)/, "").strip.upcase
      COMPONENT_HEADINGS.fetch(component) { [ titleize(component.to_s) ] }.any? do |heading|
        words == heading.upcase || words.end_with?(" #{heading.upcase}")
      end
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
