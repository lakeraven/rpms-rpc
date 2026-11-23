# frozen_string_literal: true

require "date"
require_relative "../client"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "../shape"

module RpmsRpc
  # CRS, the IHS Clinical Reporting System (namespace BGP), through the Visual
  # CRS RPC interface: the National GPRA report and the National GPRA patient
  # lists, queued, polled and read back (rpms-rpc#920).
  #
  # ## The wire
  #
  # Every `BGPG 25 ...` RPC is a GLOBAL ARRAY (type 4) with one positional
  # string parameter. Values inside it are split on "|" and sub-values on "~",
  # so a value carrying "|", "~" or "^" is refused before anything is sent.
  # The reply is a BMX-ADO table:
  #
  #   header node  "<T|I|D|F><5-digit width><Name>^..."   then $C(30)
  #   row nodes    "value^value^..."                      then $C(30)
  #   end node     $C(31) [trailer]
  #
  # A trapped M error is a table of its own: header T00250MError, one row
  # "0|MUMPS error: ..." (ERR^BGPXGU). The entry points that trap to
  # MERR^BGPGU keep their own header and write "ERROR|MUMPS error: ..." as the
  # first row (ERR^BGPGU). Either raises ServerError; a reply without its typed
  # header raises ReplyError. Neither is ever an empty list.
  #
  # The module reads through CiaClient#call_rpc_global_array when the client
  # offers it, and through call_rpc (BmxClient: the table as lines, header kept)
  # otherwise. Over BMX, BGPG 25 GET NATIONAL GPRA ends its array with
  # $C(31)_"MERR^BGPXGU" (ONTL^BGPXGR sets X to its trap label and writes $G(X)
  # after the end node), which BmxClient reads as a query error, so the report
  # output is readable over CIA only.
  #
  # ## Context
  #
  # The RPCs are registered under one option, BGPGRPC, and nowhere else; every
  # method binds it through ContextScope and restores the caller's option. A
  # user without BGPGRPC on the menu tree is refused by the broker
  # (Client::RpcRefusedError over CIA, Client::ContextBindRefusedError over
  # BMX); the refusal propagates.
  #
  # ## Reports run in TaskMan
  #
  # queue_national_gpra and queue_patient_lists file a BGP 25 GUI REPORT OUTPUT
  # (#90569.19) entry and a TaskMan task, and answer the entry's ien.
  # report_status lists the signed-on user's entries; wait_for_report polls it
  # until the report completes, errors, disappears or the caller's timeout
  # passes. report_output reads the finished report's lines.
  module Crs
    extend self
    extend Shape::Declarable

    # The one option the BGPG 25 RPCs are registered under.
    CONTEXT = "BGPGRPC"

    SITE_PARAMETERS_RPC = "BGPG 25 GET SITE PARAMETERS"
    COMMUNITY_TAXONOMY_RPC = "BGPG 25 CHK COMM TAX NTL"
    TAXONOMIES_RPC = "BGPG 25 GET TAXONOMY"
    INDICATORS_RPC = "BGPG 25 GPRA INDICATORS"
    NATIONAL_GPRA_RPC = "BGPG 25 NATIONAL GPRA RPT NTL"
    PATIENT_LISTS_RPC = "BGPG 25 NATIONAL GPRA LISTS"
    REPORT_STATUS_RPC = "BGPG 25 CHECK REPORT STATUS"
    REPORT_OUTPUT_RPC = "BGPG 25 GET NATIONAL GPRA"

    # The package namespace GETTAX^BGPXGT looks up in ^DIC(9.4,"C"): CRS.
    PACKAGE = "BGP"
    # GI^BGPXGT report type 1: the National GPRA measure set.
    NATIONAL_GPRA = "1"

    # Output type, piece 3 (NTL) or 4 (NPL): printed report, delimited, both.
    OUTPUTS = { printed: "P", delimited: "D", both: "B" }.freeze
    # Beneficiary population, NPL piece 10.
    POPULATIONS = { aian: "1", non_aian: "2", all: "3" }.freeze
    # Report-period quarters 1-4 (NPL piece 6): the period ends in January-
    # December, April-March, July-June or October-September of the year.
    # Quarter 5, a user-defined end date, is `period: { ends: Date }`.
    QUARTERS = (1..4)

    # CHECK REPORT STATUS's .06 status (external), as CHK^BGPXGU reports it.
    COMPLETED = "COMPLETED"
    ERRORED = "ERRORED"

    DELIMITERS = /[|~^]/
    RECORD_SEP = "\x1e" # $C(30), after every node
    ARRAY_END = "\x1f"  # $C(31), the end node
    ACK = "\x00"
    HEADER_PIECE = /\A[ITDF]\d{5}\S/
    MERROR_HEADER = /\A[ITDF]\d{5}MError\z/
    ERROR_ROW = /\AERROR\|/
    TAXONOMY_ROW = %r{\A(?<name>.+)\((?<state>Read Only|Editable)/(?<kind>[^/()]+)/(?<file>[\d.]+)\)\z}

    class Error < RpmsRpc::Error; end
    # CRS trapped an M error (the MError table, or an ERROR| row).
    class ServerError < Error; end
    # The reply was not the table the RPC answers (no typed header, no reply).
    class ReplyError < Error; end
    # CRS refused to queue the report (0 or 0^reason).
    class QueueRefusedError < Error; end
    # The report errored, or is no longer among the user's reports.
    class ReportFailedError < Error; end
    # The caller's timeout passed while the report was still queued or running.
    # Not a broker timeout: the broker answered every poll.
    class TimeoutError < Error; end

    # BGPG 25 GET SITE PARAMETERS (SP^BGPXGU). location: a LOCATION (#4) ien,
    # or nil for the signed-on division (DUZ(2)). One hash per BGP SITE
    # PARAMETERS entry: { ien:, location:, home_location:, community_taxonomy:,
    # eiss: }, each pointer { ien:, name: } or nil when unset. [] when the
    # division has no entry.
    def site_parameters(location: nil)
      site = location.nil? ? "" : positive_ien!(location, "location")
      table(SITE_PARAMETERS_RPC, site).map do |row|
        { ien: row[0].to_i, location: pointer(row[1]), home_location: pointer(row[2]),
          community_taxonomy: pointer(row[3]), eiss: row[4].to_s == "1" }
      end
    end
    shape :site_parameters, resource: "crs", verb: "GET", path: "/crs/site-parameters"

    # BGPG 25 CHK COMM TAX NTL (COMCHK^BGPXGUA): the warnings CRS raises about
    # a community taxonomy, one per community that is in the taxonomy but not
    # in the standard community table. It does not list the communities; a
    # clean taxonomy answers no warnings. taxonomy: a TAXONOMY ien (a positive
    # integer; COMCHK traps on anything else, so it is refused before sending).
    # Returns { taxonomy_ien:, warnings: [String] }.
    def community_taxonomy(taxonomy)
      ien = positive_ien!(taxonomy, "community taxonomy")
      warnings = table(COMMUNITY_TAXONOMY_RPC, ien).map(&:first)
      { taxonomy_ien: ien.to_i, warnings: warnings }
    end
    shape :community_taxonomy, resource: "crs", verb: "GET", path: "/crs/community-taxonomies/{taxonomy}"

    # BGPG 25 GET TAXONOMY (GETTAX^BGPXGT, package BGP): the CRS taxonomies and
    # their state. One hash per taxonomy: { name:, read_only:, kind: ("Tax",
    # "Med" or "Lab"), file: (the file number as a String) }. Community
    # taxonomies are not package taxonomies and are not listed.
    def taxonomies
      table(TAXONOMIES_RPC, PACKAGE).map do |row|
        text = row.join("^")
        m = text.match(TAXONOMY_ROW)
        raise ReplyError, "#{TAXONOMIES_RPC}: a row is not NAME(state/kind/file)" if m.nil?

        { name: m[:name], read_only: m[:state] == "Read Only", kind: m[:kind], file: m[:file] }
      end
    end
    shape :taxonomies, resource: "crs", verb: "GET", path: "/crs/taxonomies"

    # BGPG 25 GPRA INDICATORS (GI^BGPXGT, report type 1): the National GPRA
    # measures, [{ ien:, name: }] (BGP 25 INDICATORS iens).
    def indicators
      table(INDICATORS_RPC, NATIONAL_GPRA).map { |row| { ien: row[0].to_i, name: row[1].to_s } }
    end
    shape :indicators, resource: "crs", verb: "GET", path: "/crs/indicators"

    # BGPG 25 NATIONAL GPRA RPT NTL (NTL^BGPXGR -> EP^BGPXGNTL): queue the
    # National GPRA report for the current CRS year.
    #
    #   community_taxonomy: the community TAXONOMY ien
    #   name:               the report's name (.01 of BGP 25 GUI REPORT OUTPUT)
    #   export_to_area:     true to write the Area export file
    #   output:             :printed (default), :delimited or :both
    #   run_at:             a Time to start at; nil starts now
    #
    # Returns { report_ien:, raw: }. Raises QueueRefusedError naming CRS's
    # reason when it answers 0^reason. A write: the request is filed and a
    # TaskMan task queued.
    def queue_national_gpra(community_taxonomy:, name:, export_to_area: false, output: :printed, run_at: nil)
      pieces = [ positive_ien!(community_taxonomy, "community taxonomy"), export_to_area ? "1" : "0", output!(output), "",
                 run_time(run_at), "", "", "", name!(name), "" ]
      queued(NATIONAL_GPRA_RPC, name, table(NATIONAL_GPRA_RPC, pieces.join("|")))
    end
    shape :queue_national_gpra, resource: "crs", verb: "POST", path: "/crs/reports/national-gpra"

    # BGPG 25 NATIONAL GPRA LISTS (NPL^BGPXGR -> EP^BGPXGNPL): queue National
    # GPRA patient lists.
    #
    #   community_taxonomy: the community TAXONOMY ien
    #   name:               the report's name
    #   lists:              { measure ien => [patient list iens] } (BGP 25
    #                       INDICATORS => BGP 25 NATIONAL PATIENT LISTS)
    #   period:             { ends: Date } for the year ending that day, or
    #                       { year:, quarter: 1..4 } for a report year
    #   baseline_year:      the baseline year (Integer, e.g. 2010)
    #   population:         :aian, :non_aian or :all
    #   provider:           a provider (NEW PERSON) ien to list only that
    #                       provider's patients; nil lists all patients
    #   output:             :printed (default), :delimited or :both
    #   run_at:             a Time to start at; nil starts now
    #
    # Returns { report_ien:, raw: }. NPL answers only the number of its
    # refusal, so a refusal raises QueueRefusedError without CRS's reason.
    def queue_patient_lists(community_taxonomy:, name:, lists:, period:, baseline_year:, population:, provider: nil,
                            output: :printed, run_at: nil)
      year, quarter = period!(period)
      who = provider.nil? ? "~" : "#{positive_ien!(provider, 'provider')}~"
      pieces = [ positive_ien!(community_taxonomy, "community taxonomy"), year, who, output!(output), run_time(run_at),
                 quarter, provider.nil? ? "A" : "P", "", fm_year(baseline_year, "baseline year"),
                 POPULATIONS.fetch(population) { raise ArgumentError, "population must be one of #{POPULATIONS.keys.inspect}" },
                 name!(name), "", *lists!(lists) ]
      queued(PATIENT_LISTS_RPC, name, table(PATIENT_LISTS_RPC, pieces.join("|")))
    end
    shape :queue_patient_lists, resource: "crs", verb: "POST", path: "/crs/reports/national-gpra-patient-lists"

    # BGPG 25 CHECK REPORT STATUS (CHK^BGPXGU): the signed-on user's CRS
    # reports. One hash per report: { ien:, name:, user:, type:, status:
    # ("QUEUED", "RUNNING", "COMPLETED" or "ERRORED"), output_type:,
    # export_files:, started_at:, ended_at: } (Times, nil when unset).
    #
    # A write: CHK^BGPXGU deletes a report with no end time whose start is more
    # than seven days old while it lists.
    def report_status
      duz = RpmsRpc.client.duz.to_s
      raise Error, "#{REPORT_STATUS_RPC} lists the signed-on user's reports; the session has no DUZ" unless duz.match?(/\A[1-9]\d*\z/)

      table(REPORT_STATUS_RPC, duz).map do |row|
        { ien: row[0].to_i, name: row[1].to_s, user: row[2].to_s, type: row[5].to_s, status: row[6].to_s,
          output_type: row[7].to_s, export_files: row[8].to_s, started_at: fm_time(row[9]), ended_at: fm_time(row[10]) }
      end
    end
    shape :report_status, resource: "crs", verb: "GET", path: "/crs/reports"

    # BGPG 25 GET NATIONAL GPRA (ONTL^BGPXGR): the lines of a report's output,
    # in order, "\f" where the print formatter broke a page. [] when nothing is
    # filed for the report (not yet run, or no such report).
    def report_output(report_ien)
      table(REPORT_OUTPUT_RPC, positive_ien!(report_ien, "report"), keep_blank: true).map { |row| row.join("^") }
    end
    shape :report_output, resource: "crs", verb: "GET", path: "/crs/reports/{report_ien}/output"

    # Poll report_status every `interval` seconds until the report is
    # COMPLETED (its row is returned). Raises ReportFailedError when it is
    # ERRORED or no longer among the user's reports, and TimeoutError naming
    # the report and its last status when `timeout` seconds pass first.
    # report_ien: the ien, or the hash a queue method returned.
    def wait_for_report(report_ien, timeout:, interval: 5)
      ien = positive_ien!(report_ien.is_a?(Hash) ? report_ien[:report_ien] : report_ien, "report").to_i
      raise ArgumentError, "timeout must be a positive number of seconds" unless timeout.is_a?(Numeric) && timeout.positive?
      raise ArgumentError, "interval must be a non-negative number of seconds" unless interval.is_a?(Numeric) && !interval.negative?

      deadline = monotonic + timeout
      loop do
        row = report_status.find { |r| r[:ien] == ien }
        raise ReportFailedError, "CRS report #{ien} is not among the signed-on user's reports" if row.nil?
        return row if row[:status] == COMPLETED
        raise ReportFailedError, "CRS report #{ien} (#{row[:name]}) #{row[:status]}" if row[:status] == ERRORED

        if monotonic >= deadline
          raise TimeoutError, "CRS report #{ien} (#{row[:name]}) was still #{row[:status]} after #{timeout}s"
        end

        sleep(interval) if interval.positive?
      end
    end
    shape :wait_for_report, resource: "crs", verb: "GET", path: "/crs/reports/{report_ien}/completion"

    private

    # The rows of an RPC's table, each split on "^", under BGPGRPC. Blank rows
    # are dropped unless keep_blank (report output keeps its blank lines).
    def table(rpc_name, param, keep_blank: false)
      raw = ContextScope.scoped(RpmsRpc.client, CONTEXT) do
        client = RpmsRpc.client
        if client.respond_to?(:call_rpc_global_array)
          client.call_rpc_global_array(rpc_name, param)
        else
          client.call_rpc(rpc_name, param)
        end
      end
      parse_table(rpc_name, raw, keep_blank: keep_blank)
    end

    def parse_table(rpc_name, raw, keep_blank:)
      nodes = nodes_of(raw)
      raise ReplyError, "#{rpc_name}: no reply" if nodes.nil? || nodes.empty?

      header = nodes.shift
      raise ReplyError, "#{rpc_name}: the reply has no typed table header" unless header?(header)

      rows = keep_blank ? nodes : nodes.reject(&:empty?)
      if header.match?(MERROR_HEADER)
        raise ServerError, "#{rpc_name}: CRS trapped an M error: #{rows.join(' ')}"
      end
      raise ServerError, "#{rpc_name}: CRS trapped an M error: #{rows.first}" if rows.first.to_s.match?(ERROR_ROW)

      rows.map { |row| row.split("^", -1) }
    end

    # The nodes of a reply: a CIA blob (sequence, ack, nodes each ending in
    # $C(30)) or a line Array (BMX, header kept). nil for no reply at all.
    def nodes_of(raw)
      case raw
      when nil then nil
      when Array
        lines = raw.map { |line| line.to_s.delete(ARRAY_END).delete_suffix(RECORD_SEP) }
        lines.pop while lines.last == ""
        lines
      when String
        body = raw.to_s
        body = body.split(ACK, 2).last.to_s if body.include?(ACK)
        body = body.split(ARRAY_END, 2).first.to_s
        nodes = body.split(RECORD_SEP, -1)
        nodes.pop if nodes.last == "" # the separator after the last node
        nodes
      else
        raise ReplyError, "unexpected reply type #{raw.class}"
      end
    end

    def header?(node)
      pieces = node.to_s.split("^", -1)
      !pieces.empty? && pieces.all? { |piece| piece.match?(HEADER_PIECE) }
    end

    # The report ien a queue RPC answered, or the refusal it gave.
    def queued(rpc_name, name, rows)
      raw = rows.first&.join("^")
      raise ReplyError, "#{rpc_name}: no report ien in the reply" if raw.nil?

      ien = raw.split("~", 2).first
      return { report_ien: ien.to_i, raw: raw } if ien.match?(/\A[1-9]\d*\z/)

      if raw.match?(/\A0(\^|\z)/)
        reason = raw.split("^", 2)[1]
        reason = "no reason given (the RPC answers only the number)" if reason.to_s.empty?
        raise QueueRefusedError, "#{rpc_name}: CRS refused to queue #{name}: #{reason}"
      end
      raise ReplyError, "#{rpc_name}: the reply is not a report ien"
    end

    def pointer(value)
      return nil if value.to_s.empty?

      ien, name = value.split("~", 2)
      { ien: ien.to_i, name: name.to_s }
    end

    def fm_time(value)
      value.to_s.empty? ? nil : FilemanDateParser.parse_datetime(value.to_s)
    end

    # The wire string of a positive integer ien. Refuses anything else,
    # including a String that carries a delimiter.
    def positive_ien!(value, what)
      case value
      when Integer then return value.to_s if value.positive?
      when String then return value if value.match?(/\A[1-9]\d*\z/)
      end
      raise ArgumentError, "#{what} must be a positive integer ien (got #{value.inspect})"
    end

    def name!(name)
      text = name.to_s
      raise ArgumentError, "the report name must not be blank" if text.strip.empty?
      raise ArgumentError, "the report name must not contain |, ~ or ^ (got #{text.inspect})" if text.match?(DELIMITERS)
      raise ArgumentError, "the report name must not contain control characters" if text.match?(/[[:cntrl:]]/)

      text
    end

    def output!(output)
      OUTPUTS.fetch(output) { raise ArgumentError, "output must be one of #{OUTPUTS.keys.inspect} (got #{output.inspect})" }
    end

    def run_time(run_at)
      return "" if run_at.nil?
      raise ArgumentError, "run_at must be a Time (got #{run_at.class})" unless run_at.is_a?(Time)

      FilemanDateParser.to_fileman(run_at)
    end

    # [period piece, quarter piece] for NPL pieces 2 and 6.
    def period!(period)
      raise ArgumentError, "period must be { ends: Date } or { year:, quarter: 1..4 }" unless period.is_a?(Hash)

      if period.key?(:ends)
        ends = period[:ends]
        raise ArgumentError, "period ends: must be a Date (got #{ends.inspect})" unless ends.is_a?(Date)

        [ FilemanDateParser.to_fileman(ends.is_a?(DateTime) ? ends.to_date : ends), "5" ]
      elsif period.key?(:year)
        quarter = period[:quarter]
        raise ArgumentError, "period quarter must be 1..4; a user-defined period is { ends: Date }" unless QUARTERS.include?(quarter)

        [ fm_year(period[:year], "report year"), quarter.to_s ]
      else
        raise ArgumentError, "period must be { ends: Date } or { year:, quarter: 1..4 }"
      end
    end

    # A calendar year as FileMan's YYY0000 (2010 => "3100000").
    def fm_year(year, what)
      raise ArgumentError, "#{what} must be a year such as 2010 (got #{year.inspect})" unless year.is_a?(Integer) && (1800..2699).cover?(year)

      "#{year - 1700}0000"
    end

    # NPL pieces 13..: "measure~list~list" per measure.
    def lists!(lists)
      raise ArgumentError, "lists must be { measure ien => [list iens] } with at least one measure" unless lists.is_a?(Hash) && !lists.empty?

      lists.map do |measure, list_iens|
        iens = Array(list_iens)
        raise ArgumentError, "measure #{measure.inspect} names no patient list" if iens.empty?

        [ positive_ien!(measure, "measure"), *iens.map { |list| positive_ien!(list, "patient list") } ].join("~")
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
