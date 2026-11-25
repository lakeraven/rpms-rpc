# frozen_string_literal: true

require "date"
require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
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
  #
  # A request files only when the division's BGP SITE PARAMETERS .04 INCLUDE
  # DATA IN WEB EISS? is Y or N: REPORT^BGPXUTL copies it into the report's
  # Y/N field, and any other value makes every request answer
  # 0^COULD NOT CREATE REPORT ENTRY. BGPG 25 SAVE SITE PARAMETERS files .04
  # unvalidated, so a site entry saved with another value refuses every report.
  #
  # On a YottaDB build JOBPAR^%ZOSV does not recognise a yottadb process, so
  # CHECK REPORT STATUS can read a report that is still running as ERRORED
  # (openrpms#1305), and wait_for_report then raises ReportFailedError.
  #
  # ## The RPC names
  #
  # The RPC names and their option come from the crs_* DataMapper mappings
  # (mappings/ihs.rb), the one place they are written down.
  module Crs
    extend self
    extend Shape::Declarable

    # The one option the BGPG 25 RPCs are registered under (the crs_* mappings').
    CONTEXT = DataMapper.crs_site_parameters.bound_context

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

    # The report name is the .01 of BGP 25 GUI REPORT OUTPUT (#90569.19), whose
    # input transform is K:$L(X)>60!($L(X)<3)!'(X'?1P.E) X: 3 to 60
    # characters, the first not punctuation (M's P class, which includes the
    # space). Confirmed through DDR VALIDATOR on the pinned build.
    NAME_LENGTH = (3..60)
    M_PUNCTUATION = /\A[ -\/:-@\[-`{-~]/

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
    # The reply was not the table the RPC answers (no reply, no typed header,
    # or a row whose piece count is not the header's column count).
    class ReplyError < Error; end
    # CRS refused to queue the report (0 or 0^reason).
    class QueueRefusedError < Error; end
    # The report errored, or is no longer among the user's reports.
    class ReportFailedError < Error; end
    # The caller's timeout passed while the report was still queued or running.
    # Not a broker timeout: the broker answered every poll.
    class TimeoutError < Error; end

    # The process's monotonic clock, and a real sleep.
    class Clock
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def pause(seconds) = sleep(seconds)
    end
    CLOCK = Clock.new
    private_constant :Clock, :CLOCK

    # BGPG 25 GET SITE PARAMETERS (SP^BGPXGU).
    #
    # @param location [Integer, String, nil] a LOCATION (#4) ien, or nil for
    #   the signed-on division (DUZ(2))
    # @return [Array<Hash>] one { ien:, location:, home_location:,
    #   community_taxonomy:, eiss: } per BGP SITE PARAMETERS entry, each pointer
    #   { ien:, name: } or nil when unset; [] when the division has no entry.
    #   eiss: is the 1/0 SP^BGPXGU computes from .08 *MFI SITE?, not .04
    #   INCLUDE DATA IN WEB EISS? (whose Y/N the report entry needs)
    def site_parameters(location: nil)
      site = location.nil? ? "" : positive_ien!(location, "location")
      table(DataMapper.crs_site_parameters, site).map do |row|
        { ien: row[0].to_i, location: pointer(row[1]), home_location: pointer(row[2]),
          community_taxonomy: pointer(row[3]), eiss: row[4].to_s == "1" }
      end
    end
    shape :site_parameters, resource: "crs", verb: "GET", path: "/crs/site-parameters"

    # BGPG 25 CHK COMM TAX NTL (COMCHK^BGPXGUA): the warnings CRS raises about
    # a community taxonomy, one per community that is in the taxonomy but not
    # in the standard community table. It does not list the communities.
    #
    # No warnings is not verification that the taxonomy exists: COMCHK answers
    # the bare header for a taxonomy ien that is not on file, exactly as it
    # does for a clean taxonomy. Take the ien from site_parameters.
    #
    # @param taxonomy [Integer, String] a TAXONOMY ien, a positive integer
    #   (COMCHK traps on anything else, so it is refused before sending)
    # @return [Hash] { taxonomy_ien:, warnings: [String] }
    def community_taxonomy(taxonomy)
      ien = positive_ien!(taxonomy, "community taxonomy")
      warnings = table(DataMapper.crs_community_taxonomy_check, ien).map(&:first)
      { taxonomy_ien: ien.to_i, warnings: warnings }
    end
    shape :community_taxonomy, resource: "crs", verb: "GET", path: "/crs/community-taxonomies/{taxonomy}"

    # BGPG 25 GET TAXONOMY (GETTAX^BGPXGT, package BGP): the CRS taxonomies and
    # their state. Community taxonomies are not package taxonomies and are not
    # listed.
    #
    # @return [Array<Hash>] one { name:, read_only:, kind: ("Tax", "Med" or
    #   "Lab"), file: (the file number as a String) } per taxonomy
    def taxonomies
      mapping = DataMapper.crs_taxonomies
      table(mapping, PACKAGE).map do |(text)|
        m = text.match(TAXONOMY_ROW)
        raise ReplyError, "#{mapping.rpc_name}: a row is not NAME(state/kind/file)" if m.nil?

        { name: m[:name], read_only: m[:state] == "Read Only", kind: m[:kind], file: m[:file] }
      end
    end
    shape :taxonomies, resource: "crs", verb: "GET", path: "/crs/taxonomies"

    # BGPG 25 GPRA INDICATORS (GI^BGPXGT, report type 1).
    #
    # @return [Array<Hash>] the National GPRA measures, { ien:, name: } (BGP 25
    #   INDICATORS iens)
    def indicators
      table(DataMapper.crs_indicators, NATIONAL_GPRA).map { |row| { ien: row[0].to_i, name: row[1].to_s } }
    end
    shape :indicators, resource: "crs", verb: "GET", path: "/crs/indicators"

    # BGPG 25 NATIONAL GPRA RPT NTL (NTL^BGPXGR -> EP^BGPXGNTL): queue the
    # National GPRA report for the current CRS year. A write: the request is
    # filed and a TaskMan task queued.
    #
    # @param community_taxonomy [Integer, String] the community TAXONOMY ien
    # @param name [String] the report's name, the .01 of BGP 25 GUI REPORT
    #   OUTPUT: 3 to 60 printable ASCII characters, not starting with punctuation or a space
    # @param export_to_area [Boolean] true to write the Area export file
    # @param output [Symbol] :printed (default), :delimited or :both
    # @param run_at [Time, nil] when TaskMan starts it; nil starts now. It is
    #   formatted from the Time's own clock fields, and TaskMan reads it in the
    #   server's local time, so pass a Time in the server's zone.
    # @return [Hash] { report_ien:, raw: }
    # @raise [QueueRefusedError] naming CRS's reason when it answers 0^reason
    #   (an unknown taxonomy, or 0^COULD NOT CREATE REPORT ENTRY when the site
    #   parameters' .04 is not Y or N)
    def queue_national_gpra(community_taxonomy:, name:, export_to_area: false, output: :printed, run_at: nil)
      raise ArgumentError, "export_to_area must be true or false (got #{export_to_area.inspect})" unless [ true, false ].include?(export_to_area)

      pieces = [ positive_ien!(community_taxonomy, "community taxonomy"), export_to_area ? "1" : "0", output!(output), "",
                 run_time(run_at), "", "", "", name!(name), "" ]
      queue(DataMapper.crs_national_gpra_queue, name, pieces.join("|"))
    end
    shape :queue_national_gpra, resource: "crs", verb: "POST", path: "/crs/reports/national-gpra"

    # BGPG 25 NATIONAL GPRA LISTS (NPL^BGPXGR -> EP^BGPXGNPL): queue National
    # GPRA patient lists. A write, like queue_national_gpra.
    #
    # @param community_taxonomy [Integer, String] the community TAXONOMY ien
    # @param name [String] the report's name (see queue_national_gpra)
    # @param lists [Hash{Integer=>Array<Integer>}] measure ien => an Array of
    #   patient list iens (BGP 25 INDICATORS => BGP 25 NATIONAL PATIENT LISTS);
    #   each measure once
    # @param period [Hash] { ends: Date } for the year ending that day, or
    #   { year:, quarter: 1..4 } for a report year
    # @param baseline_year [Integer] the baseline year (e.g. 2010); not later
    #   than the period's year
    # @param population [Symbol] :aian, :non_aian or :all
    # @param provider [Integer, String, nil] a provider (NEW PERSON) ien to list
    #   only that provider's patients; nil lists all patients
    # @param output [Symbol] :printed (default), :delimited or :both
    # @param run_at [Time, nil] as queue_national_gpra's
    # @return [Hash] { report_ien:, raw: }
    # @raise [QueueRefusedError] NPL answers only the number of its refusal, so
    #   the error carries no reason from CRS
    def queue_patient_lists(community_taxonomy:, name:, lists:, period:, baseline_year:, population:, provider: nil,
                            output: :printed, run_at: nil)
      year_piece, quarter, period_year = period!(period)
      baseline = fm_year(baseline_year, "baseline year")
      raise ArgumentError, "baseline year #{baseline_year} is later than the report period's year #{period_year}" if baseline_year > period_year

      who = provider.nil? ? "~" : "#{positive_ien!(provider, 'provider')}~"
      pieces = [ positive_ien!(community_taxonomy, "community taxonomy"), year_piece, who, output!(output), run_time(run_at),
                 quarter, provider.nil? ? "A" : "P", "", baseline,
                 POPULATIONS.fetch(population) { raise ArgumentError, "population must be one of #{POPULATIONS.keys.inspect}" },
                 name!(name), "", *lists!(lists) ]
      queue(DataMapper.crs_patient_lists_queue, name, pieces.join("|"))
    end
    shape :queue_patient_lists, resource: "crs", verb: "POST", path: "/crs/reports/national-gpra-patient-lists"

    # BGPG 25 CHECK REPORT STATUS (CHK^BGPXGU): the signed-on user's CRS
    # reports. A write: CHK^BGPXGU deletes a report with no end time whose
    # start is more than seven days old while it lists. On a YottaDB build a
    # running report can be listed ERRORED (openrpms#1305; see the module doc).
    #
    # @return [Array<Hash>] one { ien:, name:, user:, type:, status: ("QUEUED",
    #   "RUNNING", "COMPLETED" or "ERRORED"), output_type:, export_files:,
    #   started_at:, ended_at: } per report (Times, nil when unset)
    def report_status
      mapping = DataMapper.crs_report_status
      duz = RpmsRpc.client.duz.to_s
      raise Error, "#{mapping.rpc_name} lists the signed-on user's reports; the session has no DUZ" unless duz.match?(/\A[1-9]\d*\z/)

      table(mapping, duz).map do |row|
        { ien: row[0].to_i, name: row[1].to_s, user: row[2].to_s, type: row[5].to_s, status: row[6].to_s,
          output_type: row[7].to_s, export_files: row[8].to_s, started_at: fm_time(row[9]), ended_at: fm_time(row[10]) }
      end
    end
    shape :report_status, resource: "crs", verb: "POST", path: "/crs/reports/status-check"

    # BGPG 25 GET NATIONAL GPRA (ONTL^BGPXGR): the lines of a report's output,
    # in order, "\f" where the print formatter broke a page.
    #
    # A header-only reply is returned as [] whether the report is still
    # running, never ran or is not on file: an empty list says nothing about
    # the report. Call this after wait_for_report returns COMPLETED.
    #
    # @param report_ien [Integer, String] the report (BGP 25 GUI REPORT OUTPUT ien)
    # @return [Array<String>]
    def report_output(report_ien)
      table(DataMapper.crs_report_output, positive_ien!(report_ien, "report"), keep_blank: true).map(&:first)
    end
    shape :report_output, resource: "crs", verb: "GET", path: "/crs/reports/{report_ien}/output"

    # Poll report_status every `interval` seconds until the report is
    # COMPLETED. The last wait is cut short at the deadline, where the report
    # is polled once more before TimeoutError is raised, so the call never
    # runs past `timeout` by more than one poll.
    #
    # @param report_ien [Integer, String, Hash] the ien, or the hash a queue
    #   method returned
    # @param timeout [Numeric] seconds, required and positive
    # @param interval [Numeric] seconds between polls
    # @return [Hash] the report's report_status row
    # @raise [ReportFailedError] the report ERRORED or is no longer listed.
    #   On a YottaDB build CHECK REPORT STATUS can read a running report as
    #   ERRORED (openrpms#1305), so this can be raised for a report that later
    #   completes.
    # @raise [TimeoutError] naming the report and its last status
    def wait_for_report(report_ien, timeout:, interval: 5)
      ien = positive_ien!(report_ien.is_a?(Hash) ? report_ien[:report_ien] : report_ien, "report").to_i
      raise ArgumentError, "timeout must be a positive number of seconds" unless timeout.is_a?(Numeric) && timeout.positive?
      raise ArgumentError, "interval must be a non-negative number of seconds" unless interval.is_a?(Numeric) && !interval.negative?

      deadline = clock.now + timeout
      loop do
        row = report_status.find { |r| r[:ien] == ien }
        raise ReportFailedError, "CRS report #{ien} is not among the signed-on user's reports" if row.nil?
        return row if row[:status] == COMPLETED
        raise ReportFailedError, "CRS report #{ien} (#{row[:name]}) #{row[:status]}" if row[:status] == ERRORED

        now = clock.now
        raise TimeoutError, "CRS report #{ien} (#{row[:name]}) was still #{row[:status]} after #{timeout}s" if now >= deadline

        wait = [ interval, deadline - now ].min
        clock.pause(wait) if wait.positive?
      end
    end
    shape :wait_for_report, resource: "crs", verb: "POST", path: "/crs/reports/{report_ien}/completion"

    private

    # The rows of a mapping's table, under its option (BGPGRPC). A table of
    # more than one column is split on "^" and each row must carry exactly the
    # header's column count; a one-column table's row is kept whole (a report
    # line or a queue reply may itself contain "^"). Blank rows are dropped
    # unless keep_blank (report output keeps its blank lines).
    def table(mapping, param, keep_blank: false)
      client = RpmsRpc.client
      raw = mapping.in_context(client) do
        if client.respond_to?(:call_rpc_global_array)
          client.call_rpc_global_array(mapping.rpc_name, param)
        else
          client.call_rpc(mapping.rpc_name, param)
        end
      end
      parse_table(mapping.rpc_name, raw, keep_blank: keep_blank)
    end

    def parse_table(rpc_name, raw, keep_blank:)
      nodes = nodes_of(raw)
      raise ReplyError, "#{rpc_name}: no reply" if nodes.nil? || nodes.empty?

      header = nodes.shift
      raise ReplyError, "#{rpc_name}: the reply has no typed table header" unless header?(header)

      rows = keep_blank ? nodes : nodes.reject(&:empty?)
      raise ServerError, "#{rpc_name}: CRS trapped an M error: #{rows.join(' ')}" if header.match?(MERROR_HEADER)
      raise ServerError, "#{rpc_name}: CRS trapped an M error: #{rows.first}" if rows.first.to_s.match?(ERROR_ROW)

      columns = header.split("^", -1).size
      return rows.map { |row| [ row ] } if columns == 1

      rows.each_with_index.map do |row, index|
        pieces = row.split("^", -1)
        if pieces.size != columns
          raise ReplyError, "#{rpc_name}: row #{index + 1} has #{pieces.size} pieces, the header #{columns} columns"
        end

        pieces
      end
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

    # Send a queue RPC; the report ien it answered, or the refusal it gave.
    def queue(mapping, name, param)
      rpc_name = mapping.rpc_name
      raw = table(mapping, param).first&.first
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

    # The BGP 25 GUI REPORT OUTPUT .01 input transform, and the wire's delimiters.
    def name!(name)
      text = name.to_s
      raise ArgumentError, "the report name must not be blank" if text.strip.empty?
      raise ArgumentError, "the report name must not contain |, ~ or ^ (got #{text.inspect})" if text.match?(DELIMITERS)
      raise ArgumentError, "the report name must be printable ASCII (got #{text.inspect})" unless text.match?(/\A[ -~]+\z/)
      raise ArgumentError, "the report name must be #{NAME_LENGTH} characters (got #{text.length})" unless NAME_LENGTH.cover?(text.length)
      raise ArgumentError, "the report name must not start with punctuation or a space (got #{text.inspect})" if text.match?(M_PUNCTUATION)

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

    # [period piece, quarter piece, the period's year] for NPL pieces 2 and 6.
    def period!(period)
      raise ArgumentError, "period must be { ends: Date } or { year:, quarter: 1..4 }" unless period.is_a?(Hash)

      if period.key?(:ends)
        ends = period[:ends]
        raise ArgumentError, "period ends: must be a Date (got #{ends.inspect})" unless ends.is_a?(Date)

        [ FilemanDateParser.to_fileman(ends.is_a?(DateTime) ? ends.to_date : ends), "5", ends.year ]
      elsif period.key?(:year)
        quarter = period[:quarter]
        raise ArgumentError, "period quarter must be 1..4; a user-defined period is { ends: Date }" unless QUARTERS.include?(quarter)

        [ fm_year(period[:year], "report year"), quarter.to_s, period[:year] ]
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

      measures = lists.map do |measure, list_iens|
        raise ArgumentError, "measure #{measure.inspect}: the patient lists must be an Array (got #{list_iens.inspect})" unless list_iens.is_a?(Array)
        raise ArgumentError, "measure #{measure.inspect} names no patient list" if list_iens.empty?

        [ positive_ien!(measure, "measure"), *list_iens.map { |list| positive_ien!(list, "patient list") } ]
      end
      repeated = measures.map(&:first).tally.select { |_ien, count| count > 1 }.keys
      raise ArgumentError, "measure #{repeated.join(', ')} is given more than once" unless repeated.empty?

      measures.map { |pieces| pieces.join("~") }
    end

    # The clock wait_for_report reads and waits on: CLOCK, unless @clock holds
    # another object with #now (seconds, monotonic) and #pause(seconds), which
    # is how a test drives the wait without sleeping.
    def clock = @clock || CLOCK
  end
end
