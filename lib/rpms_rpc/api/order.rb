# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, a patient's orders and
  # the patient's unsigned actions, plus per-order result reads,
  # order-sheet catalog reads for the order-review surface, and order
  # checks when an order is accepted.
  # Underlying RPCs (layouts per FOIA ORWOR.m / ORWORR.m / ORWDXC.m, #220, #454):
  # ORWOR UNSIGN, ORWORR AGET, ORWOR RESULT,
  # ORWOR RESULT HISTORY, ORWOR ACTION TEXT, ORWOR EXPIRED, ORWOR SHEETS,
  # ORWOR TSALL, ORWDXC ACCEPT.
  module Order
    extend self

    # Order view ids from ORDSTS^ORCHANG2 (ORCHANG2.m:37-63), which AGET
    # takes as FILTER (ORWORR.m:25,34) -- the list REVSTS^ORWORDG serves.
    FILTER_IDS = {
      all:                              "1",
      active:                           "2",
      current:                          "23",
      discontinued:                     "3",
      discontinued_or_entered_in_error: "28",
      completed_or_expired:             "4",
      expiring:                         "5",
      pending:                          "7",
      on_hold:                          "18",
      new:                              "19",
      unsigned:                         "11",
      unverified:                       "8",
      unverified_by_nursing:            "9",
      unverified_by_clerk:              "10",
      unverified_chart_review:          "20",
      verbal:                           "13",
      verbal_unsigned:                  "14",
      flagged:                          "12",
      recent_activity:                  "6",
      delayed:                          "24",
      delayed_admission:                "15",
      delayed_transfer:                 "17",
      delayed_discharge:                "16",
      delayed_return_from_or:           "25",
      delayed_manual_release:           "26",
      lapsed:                           "22"
    }.freeze

    # AGET's own default display group (ORWORR.m:33).
    DEFAULT_DISPLAY_GROUP = 1

    # CDL on a CHK2LST row (ORKCHK.m:114-115). 99, blank, or anything else
    # is unknown (ORCHECK.m:88) and requires an override, as does high.
    CDL_SEVERITY = {
      "1" => :high,
      "2" => :moderate,
      "3" => :low
    }.freeze

    # ORKCHK.m:20-21 writes ^^^Order Checking Unavailable - ... (the text
    # is the reason). CHK2LST drops a row whose raw CDL piece is blank
    # (FOIA ORWDXC.m:145, stock WorldVistA ORWDXC.m:151), so that row
    # normally never reaches the wire. The fail-closed branch in
    # parse_chk2lst_row is defensive for a row that does. The reported
    # reason is "order checks unavailable: " plus that server text.
    ORDER_CHECKING_UNAVAILABLE = "Order Checking Unavailable"

    # FDBDOWN^ORCHECK (WorldVistA ORCHECK.m:192-199) writes this sentence
    # when drug checks did not run. Matched at any check ien or CDL.
    INCOMPLETE_CHECK_TEXT = "These checks could not be completed for this patient:"

    # CHKRMT^ORKCHK (WorldVistA ORKCHK.m:133-144) emits this on ACCEPT for
    # PS/RA when remote data is missing. RETURN^ORCHECK keeps pieces 2-4,
    # and CHK2LST parks check ien 99 in the RDI slot (WorldVistA
    # ORWDXC.m:149,152).
    REMOTE_ORDER_CHECKING_UNAVAILABLE = "Remote Order Checking not available"

    # ||<key>&<line> (WorldVistA ORCHECK.m:199). Key is up to the first &.
    EXTENDED_TEXT = /\A\|\|([^&]*)&(.*)\z/

    # DFN, location, and the orderable-item pointer. No sign, suffix, or
    # leading zero. invalid_id? is looser and stays shared by other methods.
    CANONICAL_ID = /\A[1-9]\d*\z/

    # Filler namespace spliced into a |-delimited ORX record
    # (WorldVistA ORWDXC.m:38,47).
    CANONICAL_FILLER_ID = /\A[A-Z][A-Z0-9]*\z/

    # OIL package piece (USID^ORWDXC, WorldVistA ORWDXC.m:110-125).
    CANONICAL_PACKAGE = /\A[A-Z][A-Z0-9]*\z/

    # FOIA ORWDXC.m:39 builds "A" (additive) or "B;<volume>". "B" alone is
    # the TYPE piece USID reads before the semicolon. Volume is free dialog
    # text; stock passes it unchanged to ENDDIV^PSJORUTL (WorldVistA
    # ORWDXC.m:117-119). A volume is non-empty and contains neither "|"
    # nor "^".
    PSIV_PKGINFO = /\A(?:A|B|B;[^|^]+)\z/

    # OPOS^ORWDXC (WorldVistA ORWDXC.m:53,214-229) shows the incomplete
    # banner once per broker job and then deletes it, so a later ACCEPT
    # for that patient can look complete. This memo copies that for one
    # client object: a DFN sticks when a raw reply line carries the
    # incomplete-checks banner or the remote-checking row (check ien 99,
    # or that sentence), even if the reply fails closed. An empty reply
    # does not. Keyed by object identity so a discarded client can be
    # collected; the value is a Hash of DFN strings and must not reference
    # the client. A different DFN, or a new client, starts clean.
    #
    # CLIENT_CHECK_LOCKS is one Mutex per client object. check holds it
    # across call_rpc and the memo read/write, so two checks on that
    # client run in the order the broker ran them. Another client's check
    # is not blocked. CLIENT_CHECK_LOCKS_MUTEX only installs that Mutex.
    # SESSION_INCOMPLETE guards the memo map and is never held across
    # call_rpc.
    #
    # A reconnect on the same client object over-reports. The new broker
    # job has an empty OPOS global, and this memo still says the DFN was
    # incomplete. That errs safe: the result stays incomplete and still
    # requires an override.
    SESSION_INCOMPLETE = Mutex.new
    SESSION_INCOMPLETE_DFNS = ObjectSpace::WeakKeyMap.new
    CLIENT_CHECK_LOCKS = ObjectSpace::WeakKeyMap.new
    CLIENT_CHECK_LOCKS_MUTEX = Mutex.new
    SESSION_INCOMPLETE_REASON =
      "order checks were reported incomplete earlier in this broker session"
    private_constant :SESSION_INCOMPLETE, :SESSION_INCOMPLETE_DFNS, :SESSION_INCOMPLETE_REASON,
                     :CLIENT_CHECK_LOCKS, :CLIENT_CHECK_LOCKS_MUTEX

    # One CHK2LST row: ORID^checkIEN^CDL^text (FOIA ORWDXC.m:138-147,
    # stock WorldVistA ORWDXC.m:128-154). check_ien is the ORDER CHECKS
    # (#100.8) pointer, the check type. ||<key>&<line> stores <line> as
    # text and <key> as extended_text_key; plain text has a nil key.
    # Incomplete when the text is the FDBDOWN banner, the check ien is
    # "99", or the text starts with the CHKRMT remote-checking sentence.
    Check = Data.define(:order_id, :check_ien, :severity, :text, :extended_text_key) do
      def incomplete?
        check_ien == "99" ||
          text.start_with?(REMOTE_ORDER_CHECKING_UNAVAILABLE) ||
          text.include?(INCOMPLETE_CHECK_TEXT)
      end

      def override_required?
        severity == :high || severity == :unknown || incomplete?
      end
    end

    # Whole ACCEPT reply. Unavailable results have no checks; an empty or
    # unreadable reply cannot be told from a failure, so it fails closed.
    # complete? is false when the reply is unavailable, any check is
    # incomplete, or this client already saw an incomplete check for the
    # same DFN (the OPOS memo above). incomplete_reason names those checks,
    # or names that order checks were reported incomplete earlier in this
    # broker session. It is nil when the result is complete, and nil when
    # the reply is unavailable (that case uses unavailable_reason).
    # override_required? is true whenever the result is not complete, and
    # also for a high or unknown check.
    CheckResult = Data.define(:available, :unavailable_reason, :checks, :incomplete_reason) do
      def self.ready(checks, incomplete_reason: nil)
        new(available: true, unavailable_reason: nil, checks: checks.freeze,
            incomplete_reason: incomplete_reason&.freeze)
      end

      def self.unavailable(reason)
        new(available: false, unavailable_reason: reason.to_s.freeze, checks: [].freeze,
            incomplete_reason: nil)
      end

      def available? = available

      def complete?
        available && incomplete_reason.nil? && checks.none?(&:incomplete?)
      end

      def override_required?
        !complete? || checks.any?(&:override_required?)
      end
    end

    # The patient's unsigned order actions the signed-on user may sign.
    # Each row: { order_id: "IFN;ACT", ien:, action_ien: }.
    #
    # UNSIGN(LST,ORVP,HAVE) (ORWOR.m:114) takes the PATIENT; the user is the
    # session DUZ. It answers nothing when that user lacks ORES (ORWOR.m:116)
    # or OR UNSIGNED ORDERS ON EXIT is off (ORWOR.m:120), which reads the
    # same as "none unsigned".
    def unsigned_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.orders_unsigned.fetch_many(dfn.to_s)).map do |row|
        ien, action = row[:order_id].to_s.split(";", 2)
        { order_id: row[:order_id], ien: ien.to_i, action_ien: action.to_i }
      end
    end

    # A patient's orders under one ORCHANG2 view (FILTER_IDS) and display
    # group (a file 100.98 IEN). Each row:
    # { order_id: "IFN;ACT", ien:, display_group_ien:, action_datetime:,
    #   event_ien:, event_name: } (ORWORR1.m:11). No order text: AGET does
    # not return it.
    def list(dfn, filter: :active, display_group: DEFAULT_DISPLAY_GROUP)
      return [] if invalid_id?(dfn)

      filter_id = FILTER_IDS[filter]
      raise ArgumentError, "unknown filter: #{filter.inspect}" if filter_id.nil?

      reply = RpmsRpc.client.call_rpc(DataMapper.orders_list.rpc_name,
                                      dfn.to_s, filter_id, display_group.to_s)
      DataMapper.orders_list.parse_many(drop_aget_header(reply))
    end

    # Result text for a single order. Returns the raw text blob or nil
    # if the order is unknown / has no result.
    #
    # Formals: RESULT(REF,DFN,ORID,ID) (ORWOR.m:29-34): DFN builds the
    # patient variable pointer, and ORDERS^ORCXPND1 reads ID as the file
    # 100 IEN (ORCXPND1.m:91). The order IEN fills both ORID and ID. An
    # IEN-only frame put the IEN in DFN and died in M on ID (#259).
    def result(dfn, order_ien)
      return nil if invalid_id?(dfn) || invalid_id?(order_ien)

      text = DataMapper.order_result.fetch_text(dfn.to_s, order_ien.to_s, order_ien.to_s)
      return nil if blank?(text)

      text
    end

    # Result history report for an order: the formatted text ORDHIST^ORWOR2
    # writes, or nil when the order is unknown or nothing came back.
    # Formals: RESHIST(REF,DFN,ORID,ID) (ORWOR.m:36), the same as RESULT, so
    # the order IEN fills ORID and ID (ORWOR2.m:7 reads +ID).
    def result_history(dfn, order_ien)
      return nil if invalid_id?(dfn) || invalid_id?(order_ien)

      text = DataMapper.order_result_history.fetch_text(dfn.to_s, order_ien.to_s, order_ien.to_s)
      return nil if blank?(text)

      text
    end

    # Free-text describing the user-facing action available on an order.
    # Returns nil if either argument is blank.
    def action_text(order_ien, action_code)
      return nil if invalid_id?(order_ien) || blank?(action_code)

      text = DataMapper.order_action_text.fetch_text(order_ien.to_s, action_code.to_s)
      return nil if blank?(text)

      text
    end

    # The date/time (Time) from which to search for expired orders: NOW
    # less the ORWOR EXPIRED ORDERS hours. EXPIRED(ORY) takes no parameter
    # and says nothing about any one order (ORWOR.m:147-150). nil when
    # nothing came back.
    def expired_search_start
      DataMapper.order_expired.fetch_scalar
    end

    # Order sheets for a patient (current view, admit/transfer/discharge
    # delayed-order events). Each row:
    # { sheet_id: "TYPE;ID", event_type:, event_ref:, label: }
    # (ORWOR.m:97-105). sheet_id is the composite the client sends back.
    def sheets_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.order_sheets.fetch_many(dfn.to_s)).map do |row|
        type, ref = row[:sheet_id].to_s.split(";", 2)
        { sheet_id: row[:sheet_id], event_type: type, event_ref: ref, label: row[:label] }
      end
    end

    # Site-level catalog of order sheets, independent of patient.
    def all_sheets
      Array(DataMapper.order_sheets_all.fetch_many)
    end

    # Order checks for orderables being accepted.
    #
    # ACCEPT(LST,DFN,FID,STRT,ORL,OIL,ORIFN) (FOIA-RPMS ORWDXC.m:45). Stock
    # VistA adds an unread eighth formal ORREN (WorldVistA ORWDXC.m:23); the
    # seven shared parameters are what is sent. FID is the filler namespace
    # from FILLID^ORWDXC (ORWDXC.m:7-16), spliced into a |-delimited record
    # (WorldVistA ORWDXC.m:38,47). OIL(n) is OIptr^PKG^PkgInfo (ORWDXC.m:46),
    # indexed from 1; the package and PkgInfo are checked as USID^ORWDXC
    # reads them (WorldVistA ORWDXC.m:110-125). ORIFN is the existing order,
    # or "" for a new one. STRT may be empty. DFN, FID, location, and each
    # orderable are checked before any RPC; a bad argument comes back
    # unavailable.
    #
    # Stock ACCEPT adds REMDUPS, FDBDOWN, OPOS, and CHECKIT (WorldVistA
    # ORWDXC.m:52-55,128-154). OPOS writes ^TMP($J,"OC-OPOS",DFN)
    # (WorldVistA ORWDXC.m:53,214-229) and drops the incomplete-checks
    # banner on a later ACCEPT in that broker job. check is a
    # non-idempotent write because of that session write. The same client
    # object remembers a DFN when the raw lines carry the incomplete-checks
    # banner or the remote-checking row, including a reply that fails
    # closed. An empty reply does not. Later results for that DFN stay
    # incomplete. Two checks on one client object run one at a time, so
    # the memo follows the order the broker ran them. A reconnect on that
    # object over-reports, which errs safe: the new job has forgotten the
    # banner, and this side still refuses to call the checks complete.
    #
    # CHK2LST answers ORID^checkIEN^CDL^text (FOIA ORWDXC.m:138-147, stock
    # WorldVistA ORWDXC.m:128-154). check_ien is the ORDER CHECKS (#100.8)
    # pointer, the check type. CHK2LST drops a row whose raw CDL piece is
    # blank (FOIA ORWDXC.m:145, stock :151), so the in-band Order Checking
    # Unavailable rows (ORKCHK.m:20-21) normally never reach the wire; one
    # that does still fails the whole result closed, with reason
    # "order checks unavailable: " plus the server text. An empty reply
    # cannot be told from a failure, so it is unavailable — never "no
    # checks found". Any malformed row fails closed. Broker errors propagate.
    def check(dfn, filler_id:, location:, items:, start: "", order_id: nil)
      return check_unavailable("invalid patient id") unless strict_positive_id?(dfn)
      return check_unavailable("invalid filler id") unless canonical_filler_id?(filler_id)
      return check_unavailable("invalid location") unless strict_positive_id?(location)

      oil = oil_list(items)
      return check_unavailable(oil) if oil.is_a?(String)

      client = RpmsRpc.client
      with_client_check_lock(client) do
        reply = client.call_rpc("ORWDXC ACCEPT", dfn.to_s, filler_id.to_s, start.to_s,
                                location.to_s, oil, order_id.to_s)
        parse_accept_reply(reply, client, dfn.to_s)
      end
    end

    private

    # GET1^ORWORR1 sets the .1 node to TOT^TXTVW^ORYD (ORWORR1.m:13), and
    # .1 collates before every row, so the first line is never an order.
    def drop_aget_header(reply)
      return [] if reply.nil? || reply.empty?

      lines = reply.is_a?(String) ? reply.split(/\r?\n/) : Array(reply)
      lines.drop(1)
    end

    # Shared by the other Order reads. to_i accepts a trailing suffix
    # ("8791abc"); those methods keep this. Order.check does not.
    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # ACCEPT DFN and ORL. A positive Integer, or a canonical digit string.
    def strict_positive_id?(value)
      case value
      when Integer
        value > 0
      when String
        value.match?(CANONICAL_ID)
      else
        false
      end
    end

    def canonical_filler_id?(value)
      value.is_a?(String) && value.match?(CANONICAL_FILLER_ID)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def check_unavailable(why)
      CheckResult.unavailable("order checks unavailable: #{why}")
    end

    # Strings pass through as OIL rows. Hashes are OIptr^PKG^PkgInfo
    # (ORWDXC.m:46). The orderable pointer (first ^ piece, or
    # :orderable_item) must be a canonical id: stock ACCEPT skips a
    # non-numeric OIL (WorldVistA ORWDXC.m:35,45) and would still report
    # the other items. The package piece must be present and match
    # CANONICAL_PACKAGE. A package starting with "PS" other than "PSIV"
    # needs a positive-integer PkgInfo; "PSIV" needs PSIV_PKGINFO; any
    # other package takes any PkgInfo. No piece may contain "|", because
    # those pieces are spliced into a |-delimited record (WorldVistA
    # ORWDXC.m:38,47). Returns the rows, or a reason string when the list
    # cannot be sent. String and hash items use the same rules.
    def oil_list(items)
      return "no orderable items" unless items.is_a?(Array) && !items.empty?

      rows = items.map { |item| oil_row(item) }
      return "invalid orderable item" if rows.any?(&:nil?)

      rows
    end

    def oil_row(item)
      case item
      when String
        string_oil_row(item)
      when Hash
        hash_oil_row(item)
      end
    end

    def string_oil_row(item)
      return nil if item.strip.empty?

      pieces = item.split("^", -1)
      return nil unless acceptable_oil_pieces?(pieces)

      item
    end

    def hash_oil_row(item)
      pieces = [
        hash_field(item, :orderable_item),
        hash_field(item, :package),
        hash_field(item, :package_info)
      ]
      return nil unless acceptable_oil_pieces?(pieces)

      pieces.join("^")
    end

    # USID^ORWDXC (WorldVistA ORWDXC.m:110-125). A PS-family package other
    # than PSIV uses ORDRUG=+$P(OIL,U,3); a non-numeric PkgInfo becomes 0
    # and the drug identity is blank. PSIV is "A", "B", or "B;" plus a
    # non-empty volume with neither "|" nor "^" (PSIV_PKGINFO).
    def acceptable_oil_pieces?(pieces)
      return false if pieces.any? { |piece| piece.to_s.include?("|") }
      return false unless pieces[0].to_s.match?(CANONICAL_ID)

      package = pieces[1].to_s
      return false unless package.match?(CANONICAL_PACKAGE)

      # "^" splits the row. A PSIV volume is everything after the package,
      # so a caret inside it is still visible to PSIV_PKGINFO.
      pkginfo = package == "PSIV" ? pieces.drop(2).join("^") : pieces[2].to_s
      acceptable_pkginfo?(package, pkginfo)
    end

    def acceptable_pkginfo?(package, pkginfo)
      if package == "PSIV"
        pkginfo.match?(PSIV_PKGINFO)
      elsif package.start_with?("PS")
        pkginfo.match?(CANONICAL_ID)
      else
        true
      end
    end

    def hash_field(item, key)
      value = item.key?(key) ? item[key] : item[key.to_s]
      value.to_s
    end

    # Per-client Mutex from CLIENT_CHECK_LOCKS. The map mutex is released
    # before this Mutex is taken, and SESSION_INCOMPLETE is taken only
    # inside the block, after call_rpc has returned.
    def with_client_check_lock(client)
      lock = CLIENT_CHECK_LOCKS_MUTEX.synchronize { CLIENT_CHECK_LOCKS[client] ||= Mutex.new }
      lock.synchronize { yield }
    end

    def parse_accept_reply(reply, client, dfn)
      lines = accept_lines(reply)
      return check_unavailable("empty reply") if blank_reply?(lines)

      rows = lines.map { |line| parse_chk2lst_row(line) }
      reason = rows.find { |row| row.is_a?(String) }
      if reason || rows.any?(&:nil?)
        remember_incomplete_dfn(client, dfn) if lines.any? { |line| incomplete_raw_line?(line) }
        return check_unavailable(reason || "malformed reply")
      end

      CheckResult.ready(rows, incomplete_reason: apply_session_incomplete(client, dfn, rows))
    end

    # Banner text, or the remote-checking row: check ien 99, or the
    # CHKRMT sentence. An empty line is neither.
    def incomplete_raw_line?(line)
      text = line.to_s
      return true if text.include?(INCOMPLETE_CHECK_TEXT)
      return true if text.include?(REMOTE_ORDER_CHECKING_UNAVAILABLE)

      text.split("^", 3)[1] == "99"
    end

    def remember_incomplete_dfn(client, dfn)
      SESSION_INCOMPLETE.synchronize { write_incomplete_dfn(client, dfn) }
    end

    # Nil when this reply is complete. A reply that itself has an
    # incomplete check is remembered for (client, dfn) and names those
    # checks. A later reply for that pair names the earlier report.
    # The memo is read and written under SESSION_INCOMPLETE.
    def apply_session_incomplete(client, dfn, checks)
      SESSION_INCOMPLETE.synchronize do
        if checks.any?(&:incomplete?)
          write_incomplete_dfn(client, dfn)
          incomplete_check_reason(checks)
        elsif SESSION_INCOMPLETE_DFNS[client]&.key?(dfn)
          SESSION_INCOMPLETE_REASON
        end
      end
    end

    # Caller holds SESSION_INCOMPLETE.
    def write_incomplete_dfn(client, dfn)
      noted = SESSION_INCOMPLETE_DFNS[client]
      noted ||= {}
      noted[dfn] = true
      SESSION_INCOMPLETE_DFNS[client] = noted
    end

    def incomplete_check_reason(checks)
      named = checks.select(&:incomplete?).map { |check| "#{check.check_ien} #{check.text}" }
      "incomplete order checks: #{named.join("; ")}"
    end

    def blank_reply?(lines)
      lines.empty? || lines.all? { |line| line.strip.empty? }
    end

    def accept_lines(reply)
      case reply
      when nil
        []
      when String
        return [] if reply.strip.empty?

        reply.split(/\r?\n/)
      else
        Array(reply).map { |line| line.to_s.delete_suffix("\r") }
      end
    end

    # nil is a malformed row (the whole reply then fails closed). A String
    # is the Order Checking Unavailable server text (ORKCHK.m:20-21);
    # the caller prefixes "order checks unavailable: ". CHK2LST drops a
    # blank raw CDL piece before such a row would be sent (FOIA
    # ORWDXC.m:145, stock WorldVistA ORWDXC.m:151); failing closed here
    # is defensive. Check ien 99 is the CHKRMT remote-checking row, a
    # real check, not this sentinel.
    def parse_chk2lst_row(line)
      pieces = line.to_s.split("^", 4)
      return nil if pieces.length < 4

      order_id, check_ien, cdl, raw_text = pieces
      return raw_text if raw_text.to_s.lstrip.start_with?(ORDER_CHECKING_UNAVAILABLE)

      ien = check_ien.to_s
      return nil unless ien.match?(/\A\d+\z/)

      text, extended_key = split_extended_text(raw_text)
      Check.new(
        order_id: order_id.to_s.freeze,
        check_ien: ien.freeze,
        severity: CDL_SEVERITY.fetch(cdl.to_s, :unknown),
        text: text.freeze,
        extended_text_key: extended_key&.freeze
      )
    end

    def split_extended_text(raw)
      match = EXTENDED_TEXT.match(raw.to_s)
      return [ raw.to_s, nil ] unless match

      [ match[2], match[1] ]
    end
  end
end
