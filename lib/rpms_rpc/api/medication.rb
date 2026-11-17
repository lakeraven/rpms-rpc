# frozen_string_literal: true

require_relative "../shape"
require_relative "../fileman_date_parser"

module RpmsRpc
  module Medication
    extend self
    extend Shape::Declarable

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
    shape :for_patient, resource: "medications", verb: "GET", path: "/patients/{dfn}/medications"

    # Active inpatient and outpatient medications, one record per "~" header.
    # Underlying RPC: ORWPS ACTIVE (ACTIVE^ORWPS, ORWPS.m:17-51; see the
    # :medication_active mapping). Status is piece 9 of the OCL node for
    # every row type, read as sent — a discontinued prescription whose
    # expiration is still in the future stays DISCONTINUED, and an empty
    # status piece stays nil. :instructions and :comments are each an Array
    # of logical lines. The first line of a channel, or a line starting with
    # "\", begins a new logical line (the "\" is dropped). A continuation
    # that begins with whitespace is appended as sent; one that does not is
    # joined to the previous logical line with a single space. Each logical
    # line is then stripped. A "t" prefix is removed from comment lines
    # before that reassembly. A non-VA row carries no date: piece 4 is the
    # CPRS start date and can belong to another drug (ORWPS.m:25, :44,
    # :116-118), so :stop_date is nil and there is no :start_date key.
    # Invalid DFNs short-circuit to [] without dispatching an RPC. This does
    # not replace for_patient.
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
    shape :active_for_patient, resource: "medications", verb: "GET", path: "/patients/{dfn}/medications/active"

    # The patient's medication profile over the last +days+ (default 365),
    # as VueCentric's medication component lists it, with the IHS fields
    # ORWPS ACTIVE does not carry. Underlying RPC: BEHORXFN GETRXS
    # (GETRXS^BEHORXFN): OCL^PSOORRL from today minus DAYS, one "~" header
    # per medication, then its instruction lines and "t" comment lines.
    #
    #   profile(dfn, days: 365)
    #   => [{ order_id:, type:, name:, status:, stop_date:, order_ien:, last_filled:, days_supply:,
    #         quantity:, refills_remaining:, start_date:, prescription_number:, ndc:, rxnorm:,
    #         indication:, instructions: [], comments: [] }, ...]
    #
    # The header is "~"TYPE (OP, UD, IV or NV) ^ the twelve OCL pieces ^
    # CHRONIC ^ START ^ RX # ^ PROVIDER ^ REASON ^ DEA ^ LOCATION ^
    # INDICATION ^ DAW ^ NON-VA ^ NDC ^ RXNORM ^ ... (BEHORXFN GETRXS,
    # ADDOUT). Status is OCL piece 9 as sent (a held order reads
    # "ACTIVE/SEE DETAILS"), stop_date piece 4 except for a non-VA row.
    # Instructions and comments are grouped as for {active_for_patient}.
    def profile(dfn, days: 365)
      return [] unless dfn.to_s.match?(/\A[1-9]\d*\z/) && days.to_s.match?(/\A[1-9]\d*\z/)

      lines = DataMapper.medication_profile.lines!(dfn.to_s, days.to_s)
      raise Client::RpcError, "BEHORXFN GETRXS answered #{lines.first.inspect} before any medication" if lines.first && !lines.first.start_with?("~")

      parse_active(lines.join("\n")).zip(lines.select { |line| line.start_with?("~") }).map do |row, header|
        row.merge(profile_fields(header.delete_prefix("~").split("^", -1)))
      end
    end
    shape :profile, resource: "medications", verb: "GET", path: "/patients/{dfn}/medications/profile"

    # A medication's id as ORQQPS LIST gives it, piece 1 of a row: the
    # order or prescription number, a kind letter, ";", and O (outpatient)
    # or I (inpatient). PSOORRL writes "<IFN>R;O", "<IFN>P;O" and
    # "<IFN>N;O" (PSOORRL.m:21, :42, :122); OEL^PSOORRL sends ";I" to
    # inpatient pharmacy (PSOORRL.m:53).
    MEDICATION_ID = /\A\d+[A-Z]*;[A-Z]\z/

    # Detail text for one medication on a patient's list. Underlying RPC:
    # ORQQPS DETAIL. Formals: DETAIL(ORY,ORPT,ORMED) (ORQQPS.m:56): the
    # patient, then the medication's id from ORQQPS LIST (see
    # {MEDICATION_ID}); both go over the wire. A frame with the id alone
    # left ORMED undefined and the call died in M (#678). A medication the
    # patient does not have answers "No detailed information found."
    # (ORQQPS.m:63), returned as the text it is. nil, with nothing sent,
    # for a DFN that is not a positive integer or a medication id not of that shape.
    def find(dfn, medication_id)
      return nil unless dfn.to_s.match?(/\A[1-9]\d*\z/) && medication_id.to_s.match?(MEDICATION_ID)

      DataMapper.medication_detail.fetch_text(dfn.to_s, medication_id.to_s)
    end
    shape :find, resource: "medications", verb: "GET", path: "/patients/{dfn}/medications/{medication_id}"

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

    def profile_fields(pieces)
      value = ->(i) { pieces[i].to_s.strip.empty? ? nil : pieces[i].strip }
      { order_ien: value[8]&.to_i, refills_remaining: value[5], last_filled: FilemanDateParser.parse_date(pieces[10].to_s),
        days_supply: value[11], quantity: value[12], start_date: FilemanDateParser.parse_date(pieces[14].to_s),
        prescription_number: value[15], indication: value[20], ndc: value[23], rxnorm: value[24] }
    end

    def finish_active(row)
      row[:instructions] = row[:instructions].map(&:strip)
      row[:comments] = row[:comments].map(&:strip)
      row
    end

    # The first line of a channel, or a line starting with "\", begins a
    # new logical line (the "\" is dropped). A continuation that begins
    # with whitespace is appended as sent — wrapped chunks keep their
    # leading space (ORWPS.m:66, :82, :109; PSOORRL.m:48). One that does
    # not is joined with a single space (non-VA reason lines are raw
    # word-processing text, ORWPS.m:48 via WPVAL^ORWDXR; a unit dose with
    # no dose or sig sends its route bare, ORWPS.m:64-66). Stripping
    # happens once the logical line is complete.
    def append_logical_line(lines, line)
      if lines.empty? || line.start_with?("\\")
        lines << line.delete_prefix("\\")
      elsif line.match?(/\A\s/)
        lines[-1] += line
      else
        lines[-1] += " #{line}"
      end
    end
  end
end
