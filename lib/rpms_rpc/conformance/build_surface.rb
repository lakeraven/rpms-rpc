# frozen_string_literal: true

require "json"
require "rpms_rpc/core"

module RpmsRpc
  module Conformance
    # The RPC surface of ONE pinned rpms-ops build, read from the files rpms-ops publishes for it
    # (rpms-rpc#394, #395). This is the only reader of those files in this repo: the registered-names
    # gate, the callable gate, `rake rpc:exclusions`, `rpc:coverage`, `rpc:api_coverage`,
    # `conformance:pin`/`check` and `openapi:surface` (#395) all go through it. When
    # rpms-ops publishes one structured file of the surface (`<tag>-rpcs.json`, rpms-ops#732), it
    # becomes a second constructor here and the per-file parsers below go; callers do not change.
    #
    # The facts, as rpms-ops publishes them (rpms-ops releases/README.md, "Inventory"):
    #
    #   <tag>-broker_8994.txt     raw: one #8994 0-node per registered RPC, in IEN order
    #                             NAME^TAG^ROUTINE^RETURN VALUE TYPE^AVAILABILITY^INACTIVE^...
    #   <tag>-rpc_reach.txt       derived: whether each of those RPCs is callable, same order
    #                             NAME^REACH^ROUTINE_PRESENT^TAG_PRESENT^CONTEXTS^EXEMPT_ON
    #   <tag>-rpc_signatures.txt  raw: bin/m/ZRPCCAT.m's walk, tab-separated, tagged per line
    #                             RPC ien name tag routine return-type availability inactive word-wrap
    #                                 version suppress-rdv app-proxy raw-buffer routine-present
    #                                 tag-present formals
    #                             DESC ien text | PARAM ien seq name type max-length required
    #                             PDESC ien seq text | RET ien text; ends in EXPLICIT SUCCESS
    #   <tag>-packages_9_4.txt    raw: PREFIX^NAME^VERSION per installed package
    #
    # The registry is required; reach and signatures are read when present (a release published
    # before rpms-ops#713 has neither) and must then name the same RPCs in the same order.
    #
    # The second constructor, BuildSurface.from_rpcs_json, reads the same facts from the one structured
    # file rpms-ops#732 publishes, <tag>-rpcs.json (schema rpcs.v1, rpms-ops
    # releases/schema/rpcs.v1.schema.json): reach and signature structure, one record per RPC in byte
    # order of its name. It carries no #8994 text (DESCRIPTION, INPUT PARAMETER descriptions, RETURN
    # PARAMETER DESCRIPTION) and no IEN, MAX LENGTH, SEQUENCE NUMBER, WORD WRAP or VERSION, so those
    # fields stay empty (texts? is false).
    # Checksums are not this class's job: InventoryLock verifies the bytes before anything reads them.
    class BuildSurface
      # rpms-ops bin/rpc_reach_face.rb, in its order of precedence.
      REACH_CLASSES = %w[no-routine no-entry-point inactive client-callable broker-exempt no-context out-of-order].freeze
      # "Callable is client-callable or broker-exempt" (rpms-ops releases/README.md).
      CALLABLE = %w[client-callable broker-exempt].freeze
      # The <tag>-rpcs.json schema this reader knows (rpms-ops#732).
      RPCS_SCHEMA = "rpcs.v1"

      class Error < RpmsRpc::Error; end

      # seq is #8994.02 SEQUENCE NUMBER as stored (often empty); the array order is the walk order.
      Param = Struct.new(:seq, :name, :type, :max_length, :required, :description, keyword_init: true)

      # One registered RPC. Registry fields are always set; reach fields are nil without a reach
      # file, signature fields nil without a signatures file. package is the #9.4 package
      # ({prefix:, name:, version:}) whose PREFIX is the longest prefix of the routine, the first in
      # packages_9_4.txt among equals; nil when none is, or without a packages file.
      Rpc = Struct.new(
        :name, :ien, :tag, :routine, :return_type, :availability, :inactive,
        :reach, :routine_present, :tag_present, :contexts, :exempt_on,
        :word_wrap, :version, :formals, :description, :params, :returns, :package,
        keyword_init: true
      ) do
        # TAG^ROUTINE as #8994 stores it; nil when neither is set. An empty TAG ("^BGUPMR") is the
        # routine's first line.
        def entry_point = tag.to_s.empty? && routine.to_s.empty? ? nil : "#{tag}^#{routine}"
        def callable? = CALLABLE.include?(reach)
      end

      # One #8994 0-node line -> the registry fields of an Rpc (nil for a blank or "#" header line).
      # TAG and ROUTINE are kept as stored (nil when the line stops before them, "" when the piece is
      # empty: BPC PMR's #8994 entry has a ROUTINE and no TAG); INACTIVE 0 or empty is nil.
      def self.parse_registry_line(line)
        line = line.chomp
        return nil if line.strip.empty? || line.start_with?("#")

        name, tag, routine, return_type, availability, inactive = line.split("^")
        { name: name, tag: tag, routine: routine, return_type: blank(return_type),
          availability: blank(availability), inactive: inactive.to_s.empty? || inactive == "0" ? nil : inactive }
      end

      def self.blank(value) = value.to_s.empty? ? nil : value

      # The pinned files for TAG in DIR (data/inventories/<tag>/), by their published names.
      def self.load(dir, tag)
        path = ->(suffix) { File.join(dir, "#{tag}-#{suffix}") }
        optional = ->(suffix) { File.file?(path.(suffix)) ? path.(suffix) : nil }
        from_files(tag: tag, registry: path.("broker_8994.txt"), reach: optional.("rpc_reach.txt"),
                   signatures: optional.("rpc_signatures.txt"), packages: optional.("packages_9_4.txt"))
      end

      def self.from_files(registry:, tag: nil, reach: nil, signatures: nil, packages: nil)
        raise Error, "registry not found: #{registry}" unless File.file?(registry)

        new(tag: tag || File.basename(registry, ".txt").delete_suffix("-broker_8994"),
            registry: registry, reach: reach, signatures: signatures, packages: packages)
      end

      # The build's surface from <tag>-rpcs.json alone (rpms-ops#732). Refuses a file whose schema is
      # not rpcs.v1, that names another tag, or whose records disagree with themselves.
      def self.from_rpcs_json(path, tag: nil)
        raise Error, "rpcs.json not found: #{path}" unless File.file?(path)

        doc = begin
          JSON.parse(File.read(path, encoding: "UTF-8"))
        rescue JSON::ParserError => e
          raise Error, "#{File.basename(path)} is not JSON: #{e.message[0, 120]}"
        end
        raise Error, "#{File.basename(path)} has schema #{doc['schema'].inspect}, not #{RPCS_SCHEMA}" unless doc.is_a?(Hash) && doc["schema"] == RPCS_SCHEMA
        raise Error, "#{File.basename(path)} names tag #{doc['tag'].inspect}, not #{tag}" if tag && doc["tag"] != tag

        new(tag: doc["tag"], rpcs_json: doc, path: path)
      end

      # header: the registry's "#" lines; meta: rpcs.json's header fields (schema, tag, commit, engine,
      # rpms_version, inputs), empty for the raw files.
      attr_reader :tag, :rpcs, :packages, :header, :sources, :meta

      # From the raw files (registry: and the optional others) or a parsed rpcs.json (rpcs_json:, path:).
      def initialize(tag:, registry: nil, reach: nil, signatures: nil, packages: nil, rpcs_json: nil, path: nil)
        @tag = tag
        @header = []
        @meta = {}
        @rpcs = []
        if rpcs_json
          @meta = rpcs_json.except("rpcs")
          @sources = { rpcs: path }.compact
          read_rpcs_json(rpcs_json, path)
          @by_name = @rpcs.to_h { |r| [ r.name, r ] }
          raise Error, "#{File.basename(path.to_s)} names #{@rpcs.size - @by_name.size} RPC(s) twice" unless @by_name.size == @rpcs.size

          @packages = @rpcs.filter_map(&:package).uniq.sort_by { |p| p[:prefix] }
          return
        end

        @sources = { registry: registry, reach: reach, signatures: signatures, packages: packages }.compact
        File.foreach(registry) do |line|
          next @header << line.chomp if line.start_with?("#")

          fields = self.class.parse_registry_line(line) or next
          @rpcs << Rpc.new(**fields)
        end
        @by_name = @rpcs.to_h { |r| [ r.name, r ] }
        read_reach(reach) if reach
        read_signatures(signatures) if signatures
        @packages = packages ? read_packages(packages) : []
        assign_packages
      end

      def names = rpcs.map(&:name)
      def [](name) = @by_name[name]
      def registered?(name) = @by_name.key?(name)
      def rpcs_json? = sources.key?(:rpcs)
      def reach? = sources.key?(:reach) || rpcs_json?
      def signatures? = sources.key?(:signatures) || rpcs_json?
      # Whether the #8994 text (descriptions, return description) was read: only rpc_signatures.txt carries it.
      def texts? = sources.key?(:signatures)

      # The reach class of NAME: nil when it is not registered (or there is no reach file).
      def reach(name) = self[name]&.reach

      def callable?(name) = self[name]&.callable? || false

      # { name => why } for each of NAMES this build does not let a client call: its reach class, or
      # "not registered". The callable gate (#394) asks this of every RPC the gem sends.
      def not_callable(names)
        require_reach!
        names.each_with_object({}) do |name, out|
          rpc = self[name]
          out[name] = rpc ? rpc.reach : "not registered" unless rpc&.callable?
        end
      end

      # { name => reach class } for every registered RPC that is not callable.
      def uncallable
        require_reach!
        rpcs.reject(&:callable?).to_h { |r| [ r.name, r.reach ] }
      end

      def reach_counts
        require_reach!
        rpcs.map(&:reach).tally.sort.to_h
      end

      private

      def require_reach!
        raise Error, "#{tag}: no rpc_reach.txt pinned (a release from before rpms-ops#713; re-pin it)" unless reach?
      end

      def read_reach(path)
        rows = File.readlines(path, chomp: true).reject { |l| l.strip.empty? }
        names = rows.map { |l| l.split("^", 2).first }
        unless names == self.names
          diff = (names - self.names).first(3) + (self.names - names).first(3)
          raise Error, "#{File.basename(path)} does not name the registry's #{self.names.size} RPCs in order " \
                       "(#{names.size} rows#{"; e.g. #{diff.join(', ')}" unless diff.empty?})"
        end
        rows.each do |line|
          name, reach, routine_present, tag_present, contexts, exempt_on = line.split("^", -1)
          raise Error, "#{File.basename(path)}: #{name.inspect} has reach #{reach.inspect}, not one of #{REACH_CLASSES.join(', ')}" unless REACH_CLASSES.include?(reach)

          rpc = self[name]
          rpc.reach = reach
          rpc.routine_present = routine_present == "1"
          rpc.tag_present = tag_present == "1"
          rpc.contexts = contexts.to_s.split(";")
          rpc.exempt_on = exempt_on.to_s.split(",")
        end
      end

      # ZRPCCAT writes M text as stored: mostly ASCII, sometimes Latin-1 (bcer-9.0-20260930's XQ
      # descriptions carry a \xB7 bullet). Read binary; a line that is not valid UTF-8 is Latin-1,
      # transcoded to UTF-8.
      def self.text(raw)
        utf8 = raw.dup.force_encoding("UTF-8")
        utf8.valid_encoding? ? utf8 : raw.dup.force_encoding("ISO-8859-1").encode("UTF-8")
      end

      def read_signatures(path)
        by_ien = {}
        order = []
        complete = false
        params = 0
        File.foreach(path, chomp: true, encoding: "ASCII-8BIT") do |raw|
          line = self.class.text(raw)
          f = line.split("\t", -1)
          case f[0]
          when "RPC"
            rpc = self[f[2]] or raise Error, "#{File.basename(path)}: RPC #{f[2].inspect} is not in the registry"
            rpc.ien = f[1].to_i
            rpc.word_wrap = blank_field(f[8])
            rpc.version = blank_field(f[9])
            rpc.formals = f[15].to_s.split(",")
            rpc.description = []
            rpc.params = []
            rpc.returns = []
            by_ien[f[1]] = rpc
            order << rpc.name
          when "DESC" then signature_rpc(by_ien, f, path).description << f[2].to_s
          when "PARAM"
            params += 1
            signature_rpc(by_ien, f, path).params << Param.new(seq: blank_field(f[2]), name: f[3], type: blank_field(f[4]),
                                                               max_length: blank_field(f[5]), required: f[6] == "1", description: [])
          when "PDESC"
            # ZRPCCAT writes a parameter's PDESC lines right after its PARAM line, and SEQUENCE
            # NUMBER is often empty, so the last PARAM is the one described.
            param = signature_rpc(by_ien, f, path).params.last
            raise Error, "#{File.basename(path)}: PDESC for no PARAM (ien #{f[1]})" unless param && param.seq.to_s == f[2].to_s

            param.description << f[3].to_s
          when "RET" then signature_rpc(by_ien, f, path).returns << f[2].to_s
          else
            if line.start_with?("EXPLICIT SUCCESS")
              complete = true
              # The walk's own counts, when it reports them: a PARAM line lost in transit is a truncation too.
              { "rpcs" => order.size, "parameters" => params }.each do |key, seen|
                reported = line[/\b#{key}=(\d+)/, 1] or next
                raise Error, "#{File.basename(path)}: #{seen} #{key} read, the walk reports #{key}=#{reported}" unless reported.to_i == seen
              end
            end
            raise Error, "#{File.basename(path)} reports #{line}" if line.start_with?("EXPLICIT FAILURE")
          end
        end
        raise Error, "#{File.basename(path)} does not end in EXPLICIT SUCCESS (truncated?)" unless complete
        raise Error, "#{File.basename(path)} does not name the registry's RPCs in order (#{order.size} RPC lines)" unless order == names
      end

      def signature_rpc(by_ien, fields, path)
        by_ien[fields[1]] or raise Error, "#{File.basename(path)}: #{fields[0]} line for ien #{fields[1]} before its RPC line"
      end

      def blank_field(value) = value.to_s.empty? ? nil : value

      # rpcs.v1 records -> Rpcs. Codes are kept as stored (null when empty); INACTIVE 0 is nil, as
      # the registry reader keeps it. Its parameters list holds #8994's INPUT PARAMETERs (source
      # "8994") or, when there are none, the formals after the reply variable (source "formals");
      # params holds only the first kind, as the signatures reader does, and the second must be
      # exactly what the formals say.
      def read_rpcs_json(doc, path)
        file = File.basename(path.to_s)
        Array(doc["rpcs"]).each do |r|
          ep = r["entry_point"] || {}
          reach = r["reach"] || {}
          raise Error, "#{file}: #{r['name'].inspect} has reach #{reach['class'].inspect}, not one of #{REACH_CLASSES.join(', ')}" unless REACH_CLASSES.include?(reach["class"])

          formals = Array(ep["formals"])
          from_8994, from_formals = Array(r["parameters"]).partition { |p| p["source"] == "8994" }
          expected = from_8994.empty? ? formals.drop(1) : []
          unless from_formals.map { |p| p["name"] } == expected
            raise Error, "#{file}: #{r['name']}'s formals-sourced parameters #{from_formals.map { |p| p['name'] }} are not #{expected}"
          end

          inactive = r["inactive"]
          @rpcs << Rpc.new(
            name: r["name"], tag: ep["tag"], routine: ep["routine"], return_type: r["return_type"],
            availability: r["availability"], inactive: inactive.to_s.empty? || inactive == "0" ? nil : inactive,
            reach: reach["class"], routine_present: reach["routine_present"], tag_present: reach["tag_present"],
            contexts: Array(reach["contexts"]), exempt_on: Array(reach["exemptions"]),
            formals: formals, description: [], returns: [],
            params: from_8994.map { |p| Param.new(seq: nil, name: p["name"], type: p["type"], max_length: nil, required: p["required"] == true, description: []) },
            package: r["package"] && { prefix: r["package"]["prefix"], name: r["package"]["name"], version: r["package"]["version"] }
          )
        end
        raise Error, "#{file} lists no RPCs" if @rpcs.empty?
      end

      # Each RPC's package: the #9.4 PREFIX that is the longest prefix of its routine, the first in
      # packages_9_4.txt among equals (the rule rpms-ops#732's rpcs.json applies).
      def assign_packages
        by_length = @packages.reject { |p| p[:prefix].to_s.empty? }.each_with_index.sort_by { |p, i| [ -p[:prefix].length, i ] }.map(&:first)
        @rpcs.each { |r| r.package = r.routine.to_s.empty? ? nil : by_length.find { |p| r.routine.start_with?(p[:prefix]) } }
      end

      def read_packages(path)
        File.readlines(path, chomp: true).reject { |l| l.strip.empty? }.map do |l|
          prefix, name, version = l.split("^", 3)
          { prefix: prefix, name: name, version: version }
        end
      end
    end
  end
end
