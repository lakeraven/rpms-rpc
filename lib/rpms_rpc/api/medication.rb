# frozen_string_literal: true

require_relative "../fileman_date_parser"

module RpmsRpc
  module Medication
    extend self

    # Condensed medication list. Underlying RPC: ORQQPS LIST — verified
    # row shape ID^NAME^STOP_DATE^ROUTE^SCHEDULE^REFILLS (LIST^ORQQPS:
    # ORQQPS.m:4-55; see the :medication_list mapping). "No medications"
    # comes back as the sentinel row "^No medications found."
    # (ORQQPS.m:53) — no id, so it is dropped rather than surfaced as a
    # phantom medication. Invalid DFNs short-circuit to [] without
    # dispatching an RPC.
    #
    # Formals: LIST(ORY,ORPT,ORSTRTDT,ORSTOPDT) (ORQQPS.m:4). Both dates go
    # over the wire, empty: the routine hands them straight to
    # OCL^PSOORRL, which reads $G(BDT)/$G(EDT) and starts the list 120 days
    # back when the start is empty (PSOORRL.m:13-15). A frame with only the
    # DFN left ORSTRTDT undefined and the call died in M (#259).
    def for_patient(dfn)
      return [] if dfn.nil? || dfn.to_s.strip.empty? || dfn.to_i <= 0

      DataMapper.medication_list.fetch_many(dfn.to_s, "", "").reject { |r| r[:id].to_s.empty? }
    end

    # Active inpatient and outpatient medications, one record per "~" header.
    # Underlying RPC: ORWPS ACTIVE (ACTIVE^ORWPS, ORWPS.m:17-51; see the
    # :medication_active mapping). Status is piece 9 of the OCL node for
    # every row type, read as sent — a discontinued prescription whose
    # expiration is still in the future stays DISCONTINUED, and an empty
    # status piece stays nil. :instructions and :comments are each an Array
    # of logical lines. The first line of a channel, or a line starting with
    # "\", begins a new logical line (the "\" is dropped); any other line is
    # appended to the previous logical line as sent, then each logical line
    # is stripped. A "t" prefix is removed from comment lines before that
    # reassembly. A non-VA row carries no date: piece 4 is the CPRS start
    # date and can belong to another drug (ORWPS.m:25, :44, :116-118), so
    # :stop_date is nil and there is no :start_date key. Invalid DFNs
    # short-circuit to [] without dispatching an RPC. This does not replace
    # for_patient.
    #
    # Formals: ACTIVE(LST,DFN) (ORWPS.m:17). LST is the return array the
    # broker supplies; only DFN goes over the wire (broker_8994:
    # ORWPS ACTIVE^ACTIVE^ORWPS^2).
    def active_for_patient(dfn)
      return [] if dfn.nil? || dfn.to_s.strip.empty? || dfn.to_i <= 0

      text = DataMapper.medication_active.fetch_text(dfn.to_s)
      return [] if text.nil? || text.empty?

      parse_active(text)
    end

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.medication_detail.fetch_text(ien.to_s)
    end

    private

    # "~"TYPE^FIELDS. TYPE occupies index 0, so OCL node piece N stays at
    # index N (status, node piece 9, is piece 10 of the header line).
    def parse_active(text)
      rows = []
      current = nil
      text.each_line do |raw|
        line = raw.chomp
        if line.start_with?("~")
          rows << finish_active(current) if current
          current = active_header(line)
        elsif current.nil?
          next
        elsif line.start_with?("t")
          append_logical_line(current[:comments], line.delete_prefix("t"))
        else
          append_logical_line(current[:instructions], line)
        end
      end
      rows << finish_active(current) if current
      rows
    end

    def active_header(line)
      pieces = line.delete_prefix("~").split("^", -1)
      status = pieces[9]
      type = pieces[0].to_s
      {
        order_id: pieces[1].to_s,
        type: type,
        name: pieces[2].to_s,
        status: status.nil? || status.empty? ? nil : status,
        stop_date: active_stop_date(type, pieces[4]),
        instructions: [],
        comments: []
      }
    end

    # Piece 4 is the stop/expiration for every row type except non-VA.
    # TMPBLD never sets it (PSOORRL.m:122-123); ORWPS fills it from NVSDT,
    # the CPRS start date, which is NEWed once and can be the previous
    # row's (ORWPS.m:25, :44, :116-118). An NV record carries no date.
    def active_stop_date(type, piece)
      return nil if type == "NV"

      FilemanDateParser.parse_date(piece)
    end

    def finish_active(row)
      row[:instructions] = row[:instructions].map(&:strip)
      row[:comments] = row[:comments].map(&:strip)
      row
    end

    # The first line of a channel, or a line starting with "\", begins a
    # new logical line (the "\" is dropped). Any other line continues the
    # previous one, appended as sent — wrapped chunks keep their leading
    # space (ORWPS.m:66, :82, :109; PSOORRL.m:48). Stripping happens once
    # the logical line is complete.
    def append_logical_line(lines, line)
      if lines.empty? || line.start_with?("\\")
        lines << line.delete_prefix("\\")
      else
        lines[-1] += line
      end
    end
  end
end
