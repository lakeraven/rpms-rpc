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

      def rows(mapping_name, *pieces)
        mapping = DataMapper[mapping_name]
        mapping.parse_many(call_amhg(mapping, *pieces))
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
        response = call_amhg(mapping, *pieces)
        lines = response.is_a?(String) ? response.split(/\r?\n/) : Array(response)

        lines.filter_map do |line|
          next if line.nil?
          next if DataMapper.recordset_header_row?(line)

          stripped = DataMapper.strip_recordset_separators(line)
          stripped.empty? ? nil : stripped
        end
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
