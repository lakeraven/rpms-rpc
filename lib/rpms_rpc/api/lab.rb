# frozen_string_literal: true

require "time"
require_relative "../shape"
require_relative "../mappings"
require_relative "../fileman_date_parser"

module RpmsRpc
  # A patient's laboratory results (LAB DATA, #63) and lab orders, read the
  # way the Labs tab and VueCentric's lab cover sheet read them.
  # Underlying RPCs: ORWLRR NEWOLD (NEWOLD^LR7OGMU), ORWLRR INTERIMG
  # (INTERIMG^LR7OGM) and BEHOLRCV LIST (LIST^BEHOLRCV -> LIST^ORQOR1).
  module Lab
    extend self
    extend Shape::Declarable

    # The dates of the patient's newest and oldest lab results:
    # { newest:, oldest: }, each a Time or Date, nil when there is none.
    # NEWOLD^LR7OGMU answers NEWEST^OLDEST as FileMan dates, "^" for a
    # patient with no LAB DATA.
    def result_date_range(dfn)
      return { newest: nil, oldest: nil } unless positive_id?(dfn)

      raw = DataMapper.lab_result_date_range.lines!(dfn.to_s).first.to_s
      newest, oldest = raw.split("^", -1)
      { newest: FilemanDateParser.parse_datetime_or_date(newest.to_s), oldest: FilemanDateParser.parse_datetime_or_date(oldest.to_s) }
    end
    shape :result_date_range, resource: "labs", verb: "GET", path: "/patients/{dfn}/labs/result-date-range"

    # One specimen's results, the next one older (direction: :older, the
    # default) or newer than +from+ (a Time, Date or FileMan date), as the
    # Labs tab's Most Recent view steps through them. Underlying RPC:
    # ORWLRR INTERIMG (INTERIMG^LR7OGM, FORMAT 1). With no +from+, :older
    # sends tomorrow, so the default is the most recent specimen:
    # SELECT^LR7OGM reads a blank DATE1 as inverse date 9999999 and $Os
    # older from there, which finds nothing (rpms-rpc#840).
    #
    #   specimen(dfn, from: nil, direction: :older)
    #   => { area:, collected_at:, specimen_ien:, specimen:, accession:, provider:,
    #        tests: [{ test_ien:, name:, value:, flag:, units:, range:, loinc: }], text: [lines] }
    #
    # Line 1 is the header CH^LR7OGMC and GRID^LR7OGMG write: TEST COUNT ^
    # AREA (CH or MI) ^ COLLECTED ^ SPECIMEN IEN ^ SPECIMEN ^ ACCESSION ^
    # PROVIDER; for chemistry the next TEST COUNT lines are the results
    # (TEST IEN^NAME^VALUE^FLAG^UNITS^RANGE, LOINC in piece 15), and the rest
    # is report text (specimen comments, interpretations, released date).
    # A microbiology specimen's report is all text. nil when the patient
    # has no lab data that way (the routine answers nothing).
    def specimen(dfn, from: nil, direction: :older)
      return nil unless positive_id?(dfn) && %i[older newer].include?(direction)

      from = Date.today + 1 if from.nil? && direction == :older
      lines = DataMapper.lab_specimen.lines!(dfn.to_s, fileman(from), direction == :older ? "1" : "-1", "1")
      return nil if lines.empty?

      read_specimen(lines)
    end
    shape :specimen, resource: "labs", verb: "GET", path: "/patients/{dfn}/labs/specimen"

    # The patient's resulted specimens collected from +from+ through +to+
    # (each a Date or Time; +to+ defaults to today, and a Date covers its
    # whole day), newest first: each is a #specimen hash plus released_at
    # (the "Report Released Date/Time:" line, a Time) and status (:final
    # once released, else :pending). Steps ORWLRR INTERIMG older one
    # specimen per call, the Labs tab's Most Recent view, from each header's
    # own COLLECTED, until it answers nothing or a specimen falls before
    # +from+. INTERIMG lists a chemistry specimen once its DATE REPORT
    # COMPLETED (#63.04 .03) is set, so an unverified one is never listed.
    # [] for a bad dfn or range, sending nothing. A header that does not
    # step older raises Client::RpcError rather than loop.
    def results(dfn, from:, to: Date.today)
      floor = instant(from)
      return [] unless positive_id?(dfn) && floor && instant(to) && instant(to) >= floor

      cursor = to.is_a?(Time) ? fileman(to) : fileman(to + 1)
      previous = nil
      found = []
      loop do
        lines = DataMapper.lab_specimen.lines!(dfn.to_s, cursor, "1", "1")
        break if lines.empty?

        read = released(read_specimen(lines))
        at = instant(read[:collected_at])
        if at.nil? || (previous && at >= previous)
          raise Client::RpcError, RpmsRpc.sanitize_error("ORWLRR INTERIMG did not step older: #{lines.first.inspect}")
        end
        break if at < floor

        found << read
        previous = at
        cursor = lines.first.split("^", -1)[2]
      end
      found
    end
    shape :results, resource: "labs", verb: "GET", path: "/patients/{dfn}/labs/results"

    # The patient's lab orders over the site's cover-sheet range
    # (BEHOLRCV DATE RANGE days back, inpatient or outpatient), as
    # VueCentric's lab cover sheet lists them: [{ order_id:, text:,
    # start_at:, status: }]. LIST^ORQOR1 with display group LAB: order_id is
    # the ORDER (#100) IEN (";" and the action when one is named), text its
    # first 60 characters, status the ORDER STATUS (#100.01) name. [] when
    # the routine answers "^No orders found."; "^Error in date range." (the
    # parameter unset) raises Client::RpcError.
    def cover_sheet_orders(dfn)
      return [] unless positive_id?(dfn)

      lines = DataMapper.lab_cover_sheet_orders.lines!(dfn.to_s)
      return [] if lines == [ "^No orders found." ]

      lines.map do |line|
        id, text, start, status = line.split("^", -1)
        raise Client::RpcError, RpmsRpc.sanitize_error("BEHOLRCV LIST answered #{line.inspect}") unless id.to_s.match?(/\A[1-9]\d*(;\d+)?\z/)

        { order_id: id, text: text, start_at: FilemanDateParser.parse_datetime_or_date(start.to_s), status: status.to_s.empty? ? nil : status }
      end
    end
    shape :cover_sheet_orders, resource: "labs", verb: "GET", path: "/patients/{dfn}/labs/cover-sheet-orders"

    private

    def read_specimen(lines)
      count, area, collected, specimen_ien, specimen, accession, provider = lines.first.split("^", -1)
      unless count.to_s.match?(/\A\d+\z/) && %w[CH MI].include?(area)
        raise Client::RpcError, RpmsRpc.sanitize_error("ORWLRR INTERIMG answered header #{lines.first.inspect}")
      end

      results = area == "CH" ? lines[1, count.to_i] : []
      { area: area, collected_at: FilemanDateParser.parse_datetime_or_date(collected.to_s),
        specimen_ien: positive_id?(specimen_ien) ? specimen_ien.to_i : nil, specimen: presence(specimen),
        accession: presence(accession), provider: presence(provider),
        tests: results.map { |line| test_row(line.split("^", -1)) }, text: lines.drop(1 + results.size) }
    end

    def test_row(pieces)
      { test_ien: positive_id?(pieces[0]) ? pieces[0].to_i : nil, name: presence(pieces[1]), value: presence(pieces[2].to_s.strip),
        flag: presence(pieces[3].to_s.strip), units: presence(pieces[4]), range: presence(pieces[5]), loinc: presence(pieces[14]) }
    end

    # GRID^LR7OGMG writes $$FMTE^XLFDT(released, "5MPZ"), upper-cased:
    # "Report Released Date/Time: 11/10/2026 12:00 PM", blank when unset.
    RELEASED = %r{\AReport Released Date/Time: (\d\d/\d\d/\d{4} \d\d:\d\d [AP]M)\s*\z}

    def released(read)
      stamp = read[:text].filter_map { |line| line[RELEASED, 1] }.first
      at = stamp && Time.strptime(stamp, "%m/%d/%Y %I:%M %p")
      read.merge(released_at: at, status: at ? :final : :pending)
    end

    def instant(value)
      case value
      when Time then value
      when Date then Time.new(value.year, value.month, value.day)
      end
    end

    def fileman(value)
      case value
      when nil then ""
      when Time then FilemanDateParser.format_datetime(value)
      when Date then FilemanDateParser.format_date(value)
      else value.to_s
      end
    end

    def positive_id?(value)
      value.to_s.match?(/\A[1-9]\d*\z/)
    end

    def presence(value)
      value.to_s.empty? ? nil : value
    end
  end
end
