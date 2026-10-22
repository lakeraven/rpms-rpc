# frozen_string_literal: true

# Wire-level conformance cases, as data (rpms-ops#834).
#
# rpms-ops owns the cases (data/conformance/cases.jsonl): one JSON object per line naming an RPC,
# the context option to bind, the persona, the literal parameters and the verdict the build must
# give. This runs them at the wire through CiaClient#call_rpc_raw. It calls no API method: a case
# is a property of the build, not of this gem's API, so any client can run the same file.
#
# A row:
#   {"id":"patient-list","rpc":"ORWPT LIST ALL","context":"CIAV VUECENTRIC","persona":"programmer",
#    "params":["@~","1"],"expect":"answered","min_rows":1,"capture":{"dfn":1}}
#
#   params   each a string, or {"list":[[subscript, ..., value], ...]} for a list parameter (one
#            subscript, or several for a multi-level node like [1,0]). A string may name "${duz}"
#            (the signed-on user) or "${<case id>.<capture>}" (a value an EARLIER case captured).
#   expect   answered (the \x00 data flag) | no_data (no flag) | broker_error (the \x01 flag)
#   min_rows optional: the least number of reply rows an answered case must return
#   capture  optional: {name: piece}, the first reply row whose ^-piece is a positive number
#   scenario, trace  optional, together: a case taken from a real client trace names the rpms-ux
#            scenario the journey serves and the trace call it came from (provenance only; the runner
#            does not read them)
#
# The verdict is read from the CIA reply flag byte, as WireTrace does. A case also fails when it
# leaves bytes unread on the socket (stream_desync), drops the session (session_dropped), names a
# capture an earlier case did not produce (unresolved), or times out.
require "json"
require "timeout"
require_relative "rpc_coverage"

module RpcCoverage
  module Cases
    EXPECTS = %w[answered no_data broker_error].freeze
    KEYS = %w[id rpc context persona params expect min_rows capture scenario trace].freeze
    REQUIRED = %w[id rpc context persona params expect].freeze
    ID = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
    REF = /\$\{([a-z0-9-]+)\.([a-z_]+)\}/
    ROW_BREAK = /\r\n|\r|\n|\x1e/
    RECORDSET_END = "\x1f"

    class Error < StandardError; end
    class Unresolved < StandardError; end

    module_function

    def load(path)
      rows = File.readlines(path, chomp: true).each_with_index.filter_map do |line, i|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError => e
        raise Error, "#{path}:#{i + 1}: not JSON (#{e.message[0, 80]})"
      end
      bad = problems(rows)
      raise Error, "#{path}: #{bad.join('; ')}" unless bad.empty?

      rows
    end

    # Shape only: rpms-ops lints the file against the release's #8994 list.
    def problems(rows)
      out = []
      seen = {}
      rows.each do |r|
        id = r["id"].to_s
        missing = REQUIRED - r.keys
        out << "#{id}: missing #{missing.join(', ')}" unless missing.empty?
        extra = r.keys - KEYS
        out << "#{id}: unknown keys #{extra.join(', ')}" unless extra.empty?
        out << "#{id.inspect}: id is not lower-case-hyphenated" unless id.match?(ID)
        out << "#{id}: duplicate id" if seen.key?(id)
        out << "#{id}: expect #{r['expect'].inspect} is not one of #{EXPECTS.join(', ')}" unless EXPECTS.include?(r["expect"])
        out << "#{id}: persona #{r['persona'].inspect} is not one of #{PERSONAS.join(', ')}" unless PERSONAS.include?(r["persona"])
        JSON.generate(r["params"]).scan(REF).each do |case_id, name|
          out << "#{id}: names ${#{case_id}.#{name}}, which no earlier case captures" unless seen[case_id]&.include?(name)
        end
        seen[id] = (r["capture"] || {}).keys
      end
      out
    end

    def resolve(text, captures, duz)
      text.to_s.gsub("${duz}", duz.to_s).gsub(REF) do
        captures.dig(Regexp.last_match(1), Regexp.last_match(2)) or
          raise Unresolved, "${#{Regexp.last_match(1)}.#{Regexp.last_match(2)}} was not captured"
      end
    end

    # The parameters as CiaClient#call_rpc_raw takes them: a String, or a Hash whose key is a
    # subscript (an Array for a multi-level node).
    def wire_params(params, captures, duz)
      Array(params).map do |p|
        next resolve(p, captures, duz) unless p.is_a?(Hash)

        p.fetch("list").to_h do |*subs, value|
          [ subs.size == 1 ? subs.first : subs, resolve(value, captures, duz) ]
        end
      end
    end

    # [verdict, rows, detail] from the raw reply: seq echo, then the flag byte, then the body.
    def reply(raw)
      b = raw.to_s.b
      case b.getbyte(1)
      when 0x00
        body = b.byteslice(2..).to_s
        rows = body.split(ROW_BREAK).reject { |l| l == RECORDSET_END }
        [ "answered", rows, nil ]
      when 0x01 then [ "broker_error", [], printable(b.byteslice(2..))[0, 160] ]
      else [ "no_data", [], nil ]
      end
    end

    def capture(rows, piece)
      rows.each do |row|
        v = row.split("^", -1)[piece - 1].to_s
        return v if v.match?(/\A\d+(\.\d+)?\z/) && v.to_f.positive?
      end
      nil
    end

    def printable(str) = str.to_s.gsub(/[^\x20-\x7e]/, " ").strip

    # Runs rows against one signed-on persona. connect returns a signed-on CiaClient; it is called
    # again after a case drops or desyncs the session.
    class Runner
      attr_reader :results

      def initialize(rows, connect:, duz:, timeout: 45, leftover: nil)
        @rows = rows
        @connect = connect
        @duz = duz
        @timeout = timeout
        @leftover = leftover || method(:leftover_bytes)
        @captures = {}
        @results = []
      end

      def run(client = nil)
        client ||= @connect.call
        @rows.each do |row|
          client = @connect.call unless alive?(client)
          result, client = run_one(client, row)
          @results << result
          yield result if block_given?
        end
        client
      end

      def passed? = !@results.empty? && @results.all? { |r| r["pass"] }

      private

      def run_one(client, row)
        started = Time.now
        verdict, rows, detail = call(client, row)
        stray = alive?(client) ? @leftover.call(client) : ""
        if !stray.empty?
          verdict = "stream_desync"
          detail = "#{stray.bytesize} byte(s) left unread on the socket"
          disconnect(client)
        elsif !alive?(client) && WIRE_VERDICTS.include?(verdict)
          verdict = "session_dropped"
        end
        @captures[row["id"]] = captured(row, rows) if verdict == "answered"
        min = row["min_rows"].to_i
        pass = verdict == row["expect"] && rows.size >= min && captures_complete?(row)
        detail ||= "#{rows.size} row(s), fewer than min_rows #{min}" if verdict == "answered" && rows.size < min
        detail ||= "capture #{missing_captures(row).join(', ')} found no positive number" unless captures_complete?(row)
        result = { "id" => row["id"], "rpc" => row["rpc"], "context" => row["context"], "expect" => row["expect"],
                   "verdict" => verdict, "rows" => rows.size, "pass" => pass, "detail" => detail,
                   "secs" => (Time.now - started).round(2) }
        result["captured"] = @captures[row["id"]] || {} if row["capture"]
        [ result, client ]
      end

      # A verdict read off the wire: when the session is gone afterwards, the session is the finding.
      WIRE_VERDICTS = %w[answered no_data broker_error client_error].freeze

      def call(client, row)
        params = Cases.wire_params(row["params"], @captures, @duz)
        client.create_context(row["context"])
        raw = Timeout.timeout(@timeout) { client.call_rpc_raw(row["rpc"], *params) }
        Cases.reply(raw)
      rescue Unresolved => e
        [ "unresolved", [], e.message ]
      rescue Timeout::Error
        disconnect(client)
        [ "timeout", [], "no reply in #{@timeout}s" ]
      rescue StandardError => e
        [ "client_error", [], "#{e.class}: #{e.message}"[0, 160] ]
      end

      def captured(row, rows) = (row["capture"] || {}).transform_values { |piece| Cases.capture(rows, piece) }.compact

      def missing_captures(row) = (row["capture"] || {}).keys - (@captures[row["id"]] || {}).keys

      def captures_complete?(row) = missing_captures(row).empty?

      def alive?(client) = client.connected? && client.authenticated?

      def disconnect(client)
        client.disconnect
      rescue StandardError
        nil
      end

      # Bytes left on the socket after a reply mean the reply was not read to its end; every later
      # reply on the session would be the previous call's (rpms-rpc#254). live_runner.rb does the same.
      def leftover_bytes(client, wait: 0.3)
        sock = client.instance_variable_get(:@socket)
        return "" unless sock

        buf = +""
        deadline = Time.now + wait
        while Time.now < deadline
          begin
            buf << sock.read_nonblock(65_536)
          rescue IO::WaitReadable
            sleep 0.05
          rescue IOError, SystemCallError
            break
          end
        end
        buf
      end
    end
  end
end
