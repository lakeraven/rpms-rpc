# frozen_string_literal: true

require_relative "../../context_scope"

module RpmsRpc
  module BehavioralHealth
    # The context option the AMHG RPCs are registered under (rpms-rpc#258).
    #
    # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built
    # 9.0 image every AMHG RPC this module and its clusters call is listed in
    # the RPC multiple of ONE file-19 option, AMHGRPC ("RPMS Behavioral Health
    # GUI", 223 entries), and in no other — not the option a CIA sign-on binds
    # (CIAV VUECENTRIC) and not OR CPRS GUI CHART. A user without XUPROGMODE
    # calling them under the sign-on option never hears back (the calls ran
    # into the read timeout rather than a denial). Wire#call_amhg, the one
    # seam every AMHG call passes through, binds this and restores the
    # caller's option, the way RpmsRpc::Agg does for AGGRPC. Defined here
    # rather than in behavioral_health.rb so a cluster loaded on its own
    # (Groups, Intake, Reference, CaseManagement) still finds it.
    CONTEXT = "AMHGRPC"

    # Shared wire-decoding helpers for the AMHG surface (rpms-rpc#227).
    #
    # Every AMHG RPC takes a SINGLE pipe-delimited parameter — YottaDB rejects
    # multi-actual calls to these entry points with YDB-E-ACTLSTTOOLONG (#198).
    # {call} enforces that shape so no cluster has to remember it.
    #
    # Extend this into a cluster module:
    #
    #   module RpmsRpc
    #     module BehavioralHealth
    #       module Groups
    #         extend self
    #         extend Wire
    #         ...
    #       end
    #     end
    #   end
    module Wire
      # R="~" throughout AMHG — the separator between a pointer's internal
      # value and its external form.
      IEN_NAME_SEPARATOR = "~"

      # The row ERR^AMHGU writes when an AMHG routine's M error trap fires.
      M_ERROR_ROW = "M ERROR|"

      # Helpers for the AMHG modules that extend Wire; not part of their public API.
      private

      # One pipe-delimited actual, read as a GLOBAL ARRAY.
      #
      # Every AMHG RPC registers RETURN VALUE TYPE 4 (GLOBAL ARRAY) and
      # separates records with $C(30). $C(30) WAS also the CIA frame
      # terminator until #241 moved it to \x7f, so a plain #call_rpc
      # truncated the reply at the first separator — the end of the typed
      # header row — and every data row was silently dropped, leaving
      # parse_many returning []. That collision is gone; $C(30) is now
      # payload.
      #
      # CiaClient#call_rpc_global_array still reads to the US sentinel, and
      # remains the correct read: it frames on the $C(31) sentinel rather
      # than relying on the terminator not colliding with the payload.
      # Route through it whenever the client offers it, and fall back to
      # #call_rpc for MockClient and non-CIA clients that hand back the seeded
      # reply whole. Same pattern as RpmsRpc::Agg#call_array (agg.rb:155).
      # A few entries take NO actual at all — CLN^AMHGTVF is CLN(RETVAL) with
      # no AMHSTR formal, so even an empty string is an extra actual and
      # YottaDB raises ACTLSTTOOLONG. Pass no pieces for those.
      #
      # Runs under AMHGRPC (BehavioralHealth::CONTEXT), restoring the
      # caller's option afterward; a client that cannot scope contexts runs
      # as-is.
      def call_amhg(mapping, *pieces)
        client = RpmsRpc.client
        args = pieces.empty? ? [] : [ pieces.join("|") ]

        ContextScope.scoped(client, CONTEXT) do
          if client.respond_to?(:call_rpc_global_array)
            client.call_rpc_global_array(mapping.rpc_name, *args)
          else
            client.call_rpc(mapping.rpc_name, *args)
          end
        end
      end

      # CiaClient#call_rpc_global_array answers the raw GLOBAL ARRAY frame:
      # a sequence echo, a \x00 ack, the typed header and $C(30)-separated
      # rows, then $C(31). parse_many splits on newlines only, so the frame is
      # split first; read whole, the echo stays on the header and the header
      # is parsed as a record (rpms-rpc#673).
      def rows(mapping_name, *pieces)
        mapping = DataMapper[mapping_name]
        mapping.parse_many(frame_rows(call_amhg(mapping, *pieces)))
      end

      # GLOBAL ARRAY pieces: optional "<seq>\x00" ack, cut at $C(31), split
      # on $C(30). A body with no $C(30) is split on newlines.
      def frame_parts(response)
        body = response.is_a?(Array) ? response.join("\n") : response.to_s
        body = body.split("\x00", 2).last if body.include?("\x00")
        body = body.split("\x1f", 2).first.to_s
        body.include?("\x1e") ? body.split("\x1e") : body.split(/\r?\n/)
      end

      # The frame's rows, each without the line feed the broker may write
      # after a $C(30) (`W @X,EOL,!`, CIANBACT.m:122) and without separators.
      # Only a String (the raw frame CiaClient#call_rpc_global_array returns)
      # is split here. An Array is a client's rows already (BmxClient#call_rpc
      # splits at $C(30)), and each element stays whole, so a newline inside a
      # field never starts another record.
      #
      # A read whose routine failed answers the M error as a row: MERR^AMHGU
      # writes "M ERROR|<text>" over row 1 (AMHGU.m:108-120), and whatever
      # rows follow it are a half-written list. Raise the error rather than
      # parse it as a record (rpms-rpc#706).
      def frame_rows(response)
        parts = response.is_a?(String) ? frame_parts(response) : Array(response).map(&:to_s)
        rows = strip_frame_rows(parts)
        m_error = rows.find { |row| row.start_with?(M_ERROR_ROW) }
        raise Client::RpcMError, RpmsRpc.sanitize_error(m_error) if m_error

        rows
      end

      def strip_frame_rows(parts)
        parts.filter_map do |row|
          row = row.delete_prefix("\r\n").delete_prefix("\n").delete_prefix("\r")
          stripped = DataMapper.strip_recordset_separators(row)
          stripped.empty? ? nil : stripped
        end
      end

      def first_row(mapping_name, *pieces)
        rows(mapping_name, *pieces).first
      end

      # "412~THERAPIST,EXAMPLE" -> { ien: "412", name: "THERAPIST,EXAMPLE" }.
      # An empty column yields nil rather than a pair of blanks: AMHG emits ""
      # when the pointer is unset, and { ien: nil, name: nil } would look like
      # a record that exists but is unnamed.
      def split_ien_name(raw)
        value = raw.to_s
        return nil if value.empty?

        ien, name = value.split(IEN_NAME_SEPARATOR, 2)
        return { ien: nil, name: ien } if name.nil?

        { ien: presence(ien), name: presence(name) }
      end

      # Single-column free-text responses. Read as WHOLE LINES.
      #
      # Several AMHG text columns send raw global nodes with no caret
      # sanitisation, so caret-splitting them would fabricate fields out of
      # clinical punctuation. Check the routine before assuming otherwise.
      def text_lines(mapping_name, *pieces)
        mapping = DataMapper[mapping_name]
        # Each node of the frame is one line; the frame is split as #rows
        # splits it, so the sequence echo never rides the header (#673).
        frame_rows(call_amhg(mapping, *pieces)).reject { |line| DataMapper.recordset_header_row?(line) }
      end

      # AMHG flags are presence-based: "" is false, anything else but "0" is
      # true. Read the routine before trusting the column NAME — several are
      # inverted (a marker meaning the negative of what the name suggests).
      def flag?(value)
        v = value.to_s.strip
        !v.empty? && v != "0"
      end

      def presence(value)
        v = value.to_s
        v.empty? ? nil : v
      end
    end
  end
end
