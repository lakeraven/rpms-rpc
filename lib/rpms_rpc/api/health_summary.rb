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

    DEFAULT_TYPES = [
      { ien: "1", name: "STANDARD", description: "Standard Health Summary" },
      { ien: "2", name: "BRIEF", description: "Brief Summary" },
      { ien: "3", name: "COMPREHENSIVE", description: "Comprehensive Summary" },
      { ien: "4", name: "PATIENT", description: "Patient-Facing Summary" }
    ].freeze

    def for_patient(dfn, summary_type: "STANDARD")
      return error_summary("Invalid patient DFN") if invalid_id?(dfn)

      type_ien = summary_type_ien(summary_type)
      text = DataMapper.report_text.fetch_text("#{dfn}^#{type_ien}^")
      parse_health_summary(text, summary_type)
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
      return nil if invalid_id?(dfn)

      code = COMPONENT_TYPES[component.to_sym]
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

      parse_pwh_report(DataMapper.health_summary_report.fetch_text(dfn.to_s))
    end

    def flowsheet_definitions
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

      DataMapper.maint_items.fetch_many(dfn.to_s)
    end

    def flowsheet(dfn, flowsheet_ien:, start_date: Date.today - 365, end_date: Date.today)
      return { items: [], error: "Invalid patient DFN" } if invalid_id?(dfn) || invalid_id?(flowsheet_ien)

      response = RpmsRpc.client.call_rpc(
        DataMapper.flowsheet_data.rpc_name,
        "#{dfn}^#{flowsheet_ien}^#{format_date(start_date)}^#{format_date(end_date)}"
      )
      parse_flowsheet(response)
    end

    private

    def summary_type_ien(type_name)
      match = types.find { |type| type[:name].to_s.upcase == type_name.to_s.upcase }
      match&.dig(:ien) || "1"
    end

    def parse_health_summary(text, type)
      return error_summary("No data returned") if blank?(text)

      sections = []
      current = nil

      text.to_s.split(/\r?\n/).each do |line|
        stripped = line.strip
        if section_header?(stripped)
          sections << current if current && !blank?(current[:content])
          name, content = split_section_header(stripped)
          current = { name: titleize(name), content: content }
        elsif current
          current[:content] += "#{line}\n"
        else
          current = { name: "Summary", content: "#{line}\n" }
        end
      end

      sections << current if current && !blank?(current[:content])
      { type: type, generated_at: Time.now, sections: sections, raw_content: text }
    end

    def section_header?(stripped)
      return false if stripped.match?(/^[-=*]+$/)

      stripped.match?(/^[A-Z]{3,}:/)
    end

    def split_section_header(stripped)
      return [ stripped.gsub(/[-*:=]+/, "").strip, "" ] unless stripped.include?(":")

      name, inline_content = stripped.split(":", 2)
      content = blank?(inline_content) ? "" : "#{inline_content.strip}\n"
      [ name, content ]
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
      value.nil? || value.to_s.empty?
    end
  end
end
