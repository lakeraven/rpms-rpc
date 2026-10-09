# frozen_string_literal: true

require "rpms_rpc/core"

module RpmsRpc
  module Conformance
    # The RPC surface of ONE pinned rpms-ops build, read from the files rpms-ops publishes for it
    # (rpms-rpc#394, #395). This is the only reader of those files in this repo: the registered-names
    # gate, the callable gate, `rake rpc:exclusions`, `rpc:coverage`, `rpc:api_coverage` and
    # `conformance:pin`/`check` all go through it, and so will the OpenAPI generator (#395). When
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
    # Checksums are not this class's job: InventoryLock verifies the bytes before anything reads them.
    class BuildSurface
      # rpms-ops bin/rpc_reach_face.rb, in its order of precedence.
      REACH_CLASSES = %w[no-routine no-entry-point inactive client-callable broker-exempt no-context out-of-order].freeze
      # "Callable is client-callable or broker-exempt" (rpms-ops releases/README.md).
      CALLABLE = %w[client-callable broker-exempt].freeze

      class Error < RpmsRpc::Error; end

      # seq is #8994.02 SEQUENCE NUMBER as stored (often empty); the array order is the walk order.
      Param = Struct.new(:seq, :name, :type, :max_length, :required, :description, keyword_init: true)

      # One registered RPC. Registry fields are always set; reach fields are nil without a reach
      # file, signature fields nil without a signatures file.
      Rpc = Struct.new(
        :name, :ien, :tag, :routine, :return_type, :availability, :inactive,
        :reach, :routine_present, :tag_present, :contexts, :exempt_on,
        :word_wrap, :version, :formals, :description, :params, :returns,
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

      attr_reader :tag, :rpcs, :packages, :header, :sources

      def initialize(tag:, registry:, reach: nil, signatures: nil, packages: nil)
        @tag = tag
        @sources = { registry: registry, reach: reach, signatures: signatures, packages: packages }.compact
        @header = []
        @rpcs = []
        File.foreach(registry) do |line|
          next @header << line.chomp if line.start_with?("#")

          fields = self.class.parse_registry_line(line) or next
          @rpcs << Rpc.new(**fields)
        end
        @by_name = @rpcs.to_h { |r| [ r.name, r ] }
        read_reach(reach) if reach
        read_signatures(signatures) if signatures
        @packages = packages ? read_packages(packages) : []
      end

      def names = rpcs.map(&:name)
      def [](name) = @by_name[name]
      def registered?(name) = @by_name.key?(name)
      def reach? = sources.key?(:reach)
      def signatures? = sources.key?(:signatures)

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

      # ZRPCCAT output can carry non-UTF-8 bytes in descriptions: read binary, keep the text as
      # UTF-8 with any invalid byte replaced.
      def read_signatures(path)
        by_ien = {}
        order = []
        complete = false
        File.foreach(path, chomp: true, encoding: "ASCII-8BIT") do |raw|
          line = raw.dup.force_encoding("UTF-8").scrub("?")
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
            complete = true if line.start_with?("EXPLICIT SUCCESS")
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

      def read_packages(path)
        File.readlines(path, chomp: true).reject { |l| l.strip.empty? }.map do |l|
          prefix, name, version = l.split("^", 3)
          { prefix: prefix, name: name, version: version }
        end
      end
    end
  end
end
