# frozen_string_literal: true

require "date"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for RPMS Health Summary / GMTS-style reports.
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

    # Shape matches the :report_types mapping so callers see the same hash
    # keys/types regardless of whether the RPC was reachable.
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

    def types
      rows = DataMapper.report_types.fetch_many
      rows.empty? ? DEFAULT_TYPES.map(&:dup) : rows
    end

    def type_components(ien)
      return [] if invalid_id?(ien)

      DataMapper.report_type_components.fetch_many(ien.to_s)
    end

    def personal_wellness_report(dfn)
      return { sections: [], error: "Invalid patient DFN" } if invalid_id?(dfn)
      return { sections: [], error: "GMTS health summary not available on this server" } unless RpmsRpc.client.supports?(:health_summary_gmts)

      parse_pwh_report(DataMapper.health_summary_report.fetch_text(dfn.to_s))
    end

    def flowsheet_definitions
      return [] unless RpmsRpc.client.supports?(:health_summary_gmts)

      DataMapper.flowsheet_list.fetch_many
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

    def health_maintenance(dfn)
      return [] if invalid_id?(dfn)
      return [] unless RpmsRpc.client.supports?(:health_summary_gmts)

      DataMapper.maint_items.fetch_many(dfn.to_s)
    end

    def flowsheet(dfn, flowsheet_ien:, start_date: Date.today - 365, end_date: Date.today)
      return { items: [], error: "Invalid patient DFN" } if invalid_id?(dfn) || invalid_id?(flowsheet_ien)
      return { items: [], error: "GMTS health summary not available on this server" } unless RpmsRpc.client.supports?(:health_summary_gmts)

      response = RpmsRpc.client.call_rpc(
        DataMapper.flowsheet_data.rpc_name,
        "#{dfn}^#{flowsheet_ien}^#{format_date(start_date)}^#{format_date(end_date)}"
      )
      parse_flowsheet(response)
    end

    private

    def summary_type_ien(type_name)
      resolve_summary_type(type_name)[:ien]
    end

    # Resolve a caller-supplied summary type to the actual type that will be
    # used. Returns the matched entry from `types` when found; otherwise
    # falls back to the first available type so callers see the resolved
    # name rather than their unrecognised input.
    def resolve_summary_type(type_name)
      available = types
      match = available.find { |type| type[:name].to_s.upcase == type_name.to_s.upcase }
      return { ien: match[:ien], name: match[:name] } if match

      fallback = available.first || { ien: "1", name: "STANDARD" }
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

    def parse_pwh_report(text)
      return { sections: [] } if blank?(text)

      {
        generated_at: Time.now,
        content: text,
        sections: parse_pwh_sections(text)
      }
    end

    def parse_pwh_sections(text)
      sections = []
      current = nil

      text.to_s.split(/\r?\n/).each do |line|
        if line.match?(/^(WELLNESS|HEALTH|PREVENTIVE|LIFESTYLE|GOALS)/i)
          sections << current if current
          current = { name: titleize(line.strip), items: [] }
        elsif current && !blank?(line)
          current[:items] << line.strip
        end
      end

      sections << current if current
      sections
    end

    def parse_flowsheet(response)
      lines = response.is_a?(Array) ? response : response.to_s.split(/\r?\n/)
      return { items: [] } if lines.empty? || blank?(lines.first)

      headers = lines.first.to_s.split("^", -1)
      items = lines[1..].to_a.filter_map do |line|
        next if blank?(line)

        values = line.to_s.split("^", -1)
        headers.each_with_index.to_h do |header, index|
          [ header.downcase.gsub(/\s+/, "_").to_sym, values[index] ]
        end
      end

      { headers: headers, items: items }
    end

    def error_summary(message)
      { type: "ERROR", generated_at: Time.now, sections: [], error: message }
    end

    def format_date(date)
      date.strftime("%m/%d/%Y")
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
