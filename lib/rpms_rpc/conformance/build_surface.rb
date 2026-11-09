# frozen_string_literal: true

require "json"
require "rpms_rpc/core"

module RpmsRpc
  module Conformance
    # The RPC surface of ONE pinned rpms-ops build, read from the one document rpms-ops publishes
    # of it, <tag>-rpcs.json (rpms-ops#732; rpms-rpc#394, #395, #406). This is the only reader of
    # that document in this repo: the registered-names gate, the callable gate, Features,
    # `rake rpc:exclusions`, `rpc:coverage`, `rpc:api_coverage`, `conformance:pin`/`check` and
    # `openapi:surface` all go through it.
    #
    # The document, as rpms-ops writes it (bin/release_rpcs_json.rb, the format's authority; schema
    # releases/schema/rpcs.v1.schema.json and rpcs.v2.schema.json):
    #
    #   schema, tag, commit, engine, rpms_version   the build it describes
    #   inputs                                      sha256 of each raw file it was projected from
    #                                               (broker_8994.txt, rpc_signatures.txt, rpc_reach.txt,
    #                                               packages_9_4.txt, INVENTORY-PROVENANCE.json)
    #   rpcs                                        one record per registered RPC, in byte order of its
    #                                               name: entry point and formals, #8994 codes, INPUT
    #                                               PARAMETERs, #9.4 package, and its reach (class,
    #                                               routine/tag present, contexts, exemptions)
    #
    # rpcs.v1 carries no #8994 text (DESCRIPTION, INPUT PARAMETER descriptions, RETURN PARAMETER
    # DESCRIPTION) and no MAX LENGTH, SEQUENCE NUMBER, WORD WRAP or VERSION, so those fields stay
    # empty (texts? is false); rpcs.v2 (rpms-ops#877) carries them all (texts? is true). Neither
    # carries the IEN.
    #
    # Beside it, <tag>-contexts_19_05.txt (one row per #19.05 RPC multiple entry, tab-separated,
    # byte-sorted, under a header row OPTION TYPE LOCK RPC RPC_KEY RPC_RULES; rpms-ops#626,
    # rpms-rpc#416) answers which option serves which RPC; it is read when present.
    #
    # Checksums are not this class's job: InventoryLock verifies the bytes before anything reads them.
    class BuildSurface
      # rpms-ops bin/rpc_reach_face.rb, in its order of precedence.
      REACH_CLASSES = %w[no-routine no-entry-point inactive client-callable broker-exempt no-context out-of-order].freeze
      # "Callable is client-callable or broker-exempt" (rpms-ops releases/README.md).
      CALLABLE = %w[client-callable broker-exempt].freeze
      # The <tag>-rpcs.json schemas this reader knows: rpcs.v1 (rpms-ops#732) and rpcs.v2, which adds
      # #8994's text (rpms-ops#877). A release keeps the schema it was published with.
      RPCS_SCHEMAS = %w[rpcs.v1 rpcs.v2].freeze
      # The schemas that carry #8994's text: DESCRIPTION, RETURN PARAMETER DESCRIPTION, WORD WRAP, VERSION,
      # and each INPUT PARAMETER's description, MAXIMUM DATA LENGTH and SEQUENCE NUMBER.
      RPCS_TEXT_SCHEMAS = %w[rpcs.v2].freeze
      RPCS_SUFFIX = "rpcs.json"
      CONTEXTS_SUFFIX = "contexts_19_05.txt"

      # The header row rpms-ops writes over <tag>-contexts_19_05.txt (rpms-ops#626).
      CONTEXTS_HEADER = %w[OPTION TYPE LOCK RPC RPC_KEY RPC_RULES].freeze
      # XWBSEC.m:11-19: a session holds XUS SIGNON before any context is created, and may always run its RPCs.
      SIGNON_CONTEXT = "XUS SIGNON"

      class Error < RpmsRpc::Error; end

      # One #19 option as a broker context: its TYPE, its LOCK (#19 piece 6, nil when none) and the RPCs its
      # RPC multiple lists, each with its #19.05 RPC KEY and RULES (nil when empty).
      Context = Struct.new(:option, :type, :lock, :rpcs, keyword_init: true)

      # seq is #8994.02 SEQUENCE NUMBER as stored (often empty); the array order is the record's order.
      Param = Struct.new(:seq, :name, :type, :max_length, :required, :description, keyword_init: true)

      # One registered RPC, from its rpcs.json record. package is the #9.4 package ({prefix:, name:,
      # version:}) rpms-ops assigned it (the longest PREFIX of its routine), nil when none.
      Rpc = Struct.new(
        :name, :tag, :routine, :return_type, :availability, :inactive,
        :reach, :routine_present, :tag_present, :contexts, :exempt_on,
        :word_wrap, :version, :formals, :description, :params, :returns, :package,
        keyword_init: true
      ) do
        # TAG^ROUTINE as #8994 stores it; nil when neither is set. An empty TAG ("^BGUPMR") is the
        # routine's first line.
        def entry_point = tag.to_s.empty? && routine.to_s.empty? ? nil : "#{tag}^#{routine}"
        def callable? = CALLABLE.include?(reach)
      end

      def self.blank(value) = value.to_s.empty? ? nil : value

      # The pinned files for TAG in DIR (data/inventories/<tag>/), by their published names:
      # <tag>-rpcs.json, and <tag>-contexts_19_05.txt when it is there.
      def self.load(dir, tag)
        contexts = File.join(dir, "#{tag}-#{CONTEXTS_SUFFIX}")
        from_rpcs_json(File.join(dir, "#{tag}-#{RPCS_SUFFIX}"), tag: tag, contexts: File.file?(contexts) ? contexts : nil)
      end

      # The build's surface from <tag>-rpcs.json (rpms-ops#732). Refuses a file that is not JSON, whose
      # schema is not one this reader knows, that names another tag, lists no RPC, lists one twice or
      # out of byte order, or whose records disagree with themselves.
      def self.from_rpcs_json(path, tag: nil, contexts: nil)
        raise Error, "rpcs.json not found: #{path}" unless File.file?(path)

        doc = begin
          JSON.parse(File.read(path, encoding: "UTF-8"))
        rescue JSON::ParserError => e
          raise Error, "#{File.basename(path)} is not JSON: #{e.message[0, 120]}"
        end
        raise Error, "#{File.basename(path)} has schema #{doc['schema'].inspect}, not one of #{RPCS_SCHEMAS.join(', ')}" unless doc.is_a?(Hash) && RPCS_SCHEMAS.include?(doc["schema"])
        raise Error, "#{File.basename(path)} names tag #{doc['tag'].inspect}, not #{tag}" if tag && doc["tag"] != tag

        new(doc: doc, path: path, contexts: contexts)
      end

      # meta: the document's header fields (schema, tag, commit, engine, rpms_version, inputs).
      # sources: the files read, { rpcs:, contexts: }.
      attr_reader :tag, :rpcs, :packages, :sources, :meta

      def initialize(doc:, path:, contexts: nil)
        @tag = doc["tag"]
        @meta = doc.except("rpcs")
        @sources = { rpcs: path, contexts: contexts }.compact
        @rpcs = read_rpcs(doc, File.basename(path.to_s))
        @by_name = @rpcs.to_h { |r| [ r.name, r ] }
        @packages = @rpcs.filter_map(&:package).uniq.sort_by { |p| p[:prefix] }
        @contexts = contexts ? read_contexts(contexts) : {}
      end

      def names = rpcs.map(&:name)
      def [](name) = @by_name[name]
      def registered?(name) = @by_name.key?(name)
      # Every surface is read from rpcs.json, which carries the reach and the signature structure.
      def rpcs_json? = true
      def reach? = true
      def signatures? = true
      # Whether the #8994 text (descriptions, return description, word wrap, version, parameter max
      # length and sequence) was read: an rpcs.v2 file carries it, rpcs.v1 does not.
      def texts? = RPCS_TEXT_SCHEMAS.include?(meta["schema"])

      # The reach class of NAME: nil when it is not registered.
      def reach(name) = self[name]&.reach

      def callable?(name) = self[name]&.callable? || false

      # { name => why } for each of NAMES this build does not let a client call: its reach class, or
      # "not registered". The callable gate (#394) asks this of every RPC the gem sends.
      def not_callable(names)
        names.each_with_object({}) do |name, out|
          rpc = self[name]
          out[name] = rpc ? rpc.reach : "not registered" unless rpc&.callable?
        end
      end

      # { name => reach class } for every registered RPC that is not callable.
      def uncallable
        rpcs.reject(&:callable?).to_h { |r| [ r.name, r.reach ] }
      end

      def reach_counts
        rpcs.map(&:reach).tally.sort.to_h
      end

      # --- the contexts face: which option serves which RPC (#19.05, rpms-rpc#416) ----------------

      def contexts? = sources.key?(:contexts)

      # The Context for OPTION, nil when no #19.05 row names it.
      def context(option) = @contexts[option]

      # Why binding OPTION is refused for a user holding KEYS (CRCONTXT^XWBSEC, XWBSEC.m:30-40), nil
      # when it is not: the option is not a context on this build, or its LOCK is a key not held.
      # An option with no RPC multiple has no row, so it reads as not existing: it serves nothing anyway.
      def bind_refusal(option, keys: [])
        require_contexts!
        ctx = @contexts[option] or return "The context '#{option}' does not exist on server."
        return "#{option} is locked by #{ctx.lock}" if ctx.lock && !keys.include?(ctx.lock)

        nil
      end

      # Why NAME is refused under the bound OPTION for a user holding KEYS ($$CHK^XQCS, XWBSEC.m:22-25),
      # nil when it is not. XUS SIGNON's RPCs and broker-exempt RPCs (the reach face's broker-exempt
      # class or EXEMPT_ON, XWBSEC.m:13-15) are never refused, so sign-on is untouched. RPC_RULES (M
      # code run by XQCS) is not modelled.
      def context_refusal(option, name, keys: [])
        require_contexts!
        return nil if @contexts[SIGNON_CONTEXT]&.rpcs&.key?(name)

        rpc = self[name]
        return nil if rpc && (rpc.reach == "broker-exempt" || Array(rpc.exempt_on).any?)

        ctx = @contexts[option] or return "#{option} serves no RPC on #{tag}"
        return "#{option} does not serve #{name} on #{tag}" unless ctx.rpcs.key?(name)

        key = ctx.rpcs[name][:key]
        return "#{name} under #{option} needs key #{key}" if key && !keys.include?(key)

        nil
      end

      private

      def require_contexts!
        raise Error, "#{tag}: no contexts_19_05.txt pinned (a release from before rpms-ops#626; re-pin it)" unless contexts?
      end

      # { option => Context } from <tag>-contexts_19_05.txt. Refuses a file without rpms-ops' header,
      # a row that is not six fields, and an option whose rows disagree on TYPE or LOCK.
      def read_contexts(path)
        file = File.basename(path)
        rows = File.readlines(path, chomp: true).reject { |l| l.strip.empty? }
        header = rows.shift.to_s.split("\t", -1)
        raise Error, "#{file}: header is not #{CONTEXTS_HEADER.join(' ')} (got #{header.join(' ').inspect})" unless header == CONTEXTS_HEADER

        rows.each_with_object({}) do |line, out|
          f = line.split("\t", -1)
          raise Error, "#{file}: row #{line.inspect} has #{f.size} fields, not #{CONTEXTS_HEADER.size}" unless f.size == CONTEXTS_HEADER.size

          option, type, lock, rpc, key, rules = f.map { |v| self.class.blank(v) }
          ctx = out[option] ||= Context.new(option: option, type: type, lock: lock, rpcs: {})
          raise Error, "#{file}: #{option} has rows with TYPE/LOCK #{[ ctx.type, ctx.lock ]} and #{[ type, lock ]}" unless [ ctx.type, ctx.lock ] == [ type, lock ]

          ctx.rpcs[rpc] = { key: key, rules: rules }
        end
      end

      # rpcs.v1 / rpcs.v2 records -> Rpcs. Codes are kept as stored (null when empty); INACTIVE 0 is nil.
      # A record's parameters list holds #8994's INPUT PARAMETERs (source "8994") or, when there are none,
      # the formals after the reply variable (source "formals"); params holds only the first kind, and the
      # second must be exactly what the formals say. rpcs.v2 adds the text, as stored: each byte is the
      # Latin-1 code point of the same value. With rpcs.v1 the text fields stay empty.
      def read_rpcs(doc, file)
        rpcs = []
        text = RPCS_TEXT_SCHEMAS.include?(doc["schema"])
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
          rpcs << Rpc.new(
            name: r["name"], tag: ep["tag"], routine: ep["routine"], return_type: r["return_type"],
            availability: r["availability"], inactive: inactive.to_s.empty? || inactive == "0" ? nil : inactive,
            reach: reach["class"], routine_present: reach["routine_present"], tag_present: reach["tag_present"],
            contexts: Array(reach["contexts"]), exempt_on: Array(reach["exemptions"]),
            formals: formals, description: text ? Array(r["description"]) : [], returns: text ? Array(r["returns"]) : [],
            word_wrap: (r["word_wrap"] if text), version: (r["version"] if text),
            params: from_8994.map do |p|
              Param.new(seq: (p["sequence"] if text), name: p["name"], type: p["type"], max_length: (p["max_length"] if text),
                        required: p["required"] == true, description: text ? Array(p["description"]) : [])
            end,
            package: r["package"] && { prefix: r["package"]["prefix"], name: r["package"]["name"], version: r["package"]["version"] }
          )
        end
        raise Error, "#{file} lists no RPCs" if rpcs.empty?

        names = rpcs.map(&:name)
        dupes = names.tally.select { |_, n| n > 1 }.keys
        raise Error, "#{file} lists #{dupes.first(3).join(', ')} more than once" unless dupes.empty?
        # rpms-ops writes the records in byte order of the name; any other order is not its document.
        unless names.each_cons(2).all? { |a, b| a.b < b.b }
          raise Error, "#{file} does not list its RPCs in byte order of name (rpms-ops writes them so)"
        end

        rpcs
      end
    end
  end
end
