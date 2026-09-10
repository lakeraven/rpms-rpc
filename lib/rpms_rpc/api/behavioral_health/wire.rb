# frozen_string_literal: true

module RpmsRpc
  module BehavioralHealth
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

      # One pipe-delimited actual. Pass the pieces in wire order.
      def call_amhg(mapping, *pieces)
        RpmsRpc.client.call_rpc(mapping.rpc_name, pieces.join("|"))
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
