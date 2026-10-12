# frozen_string_literal: true

require_relative "../../lib/rpms_rpc/conformance/build_surface"
require_relative "document"

module OpenApi
  # The RPC surface of one pinned build as OpenAPI 3.1 (rpms-rpc#395): every RPC the build registers in
  # REMOTE PROCEDURE (#8994), with its arguments, its reply and its reach. Read through
  # RpmsRpc::Conformance::BuildSurface, the one reader of the pinned rpms-ops files (#394); ported from
  # rpms-ux bin/rpc-catalog.mjs. The fields are documented in docs/openapi.md.
  #
  # Each RPC is one operation, addressed as a resource: <verb> /<package>/<resource>, both derived from the
  # RPC's name by Surface.address. The path is only an address for people and viewers: the summary and
  # x-rpms.rpc keep the exact RPC name, which is what is sent over the broker.
  #   requestBody  the arguments in broker order (x-position): #8994's INPUT PARAMETERs when the RPC has any
  #                (params_source "8994"), in walk order, not by SEQUENCE NUMBER (rpms-ux#26); otherwise the
  #                entry point's formals after the first, which is the reply variable ("routine"); none
  #                when neither ("none").
  #   responses    shaped by RETURN VALUE TYPE, described by RETURN PARAMETER DESCRIPTION when there is one.
  # The tag is the package: the #9.4 PREFIX that is the longest prefix of the RPC's routine.
  module Surface
    RETURN_TYPES = { "1" => "SINGLE VALUE", "2" => "ARRAY", "3" => "WORD PROCESSING", "4" => "GLOBAL ARRAY", "5" => "GLOBAL INSTANCE" }.freeze
    PARAM_TYPES = { "1" => "LITERAL", "2" => "LIST", "3" => "WORD PROCESSING", "4" => "REFERENCE" }.freeze
    AVAILABILITY = { "P" => "PUBLIC", "S" => "SUBSCRIPTION", "A" => "AGREEMENT", "R" => "RESTRICTED" }.freeze
    INACTIVE = { "1" => "INACTIVE", "2" => "LOCAL INACTIVE (ACTIVE REMOTELY)", "3" => "REMOTE INACTIVE (ACTIVE LOCALLY)" }.freeze
    LOCALLY_ACTIVE = [ "ACTIVE", "REMOTE INACTIVE (ACTIVE LOCALLY)" ].freeze
    MEDIA = "application/x-rpms-rpc"
    METHODS = %w[get post put delete].freeze # path item order

    # Addressing: how an RPC's name becomes <verb> /<package>/<resource>. Deterministic, from the name
    # alone; nothing is curated per RPC. Words are the name split on spaces. The first word is the
    # namespace (XUS, ORWPT, BMC) when the name has more than one; a one-word name (MAGGPATINFO) has its
    # namespace fused in and keeps it, because cutting it at its #9.4 PREFIX would cut mid-namespace.
    # A verb word chooses the verb and leaves the path; a read noun chooses GET and stays in it. A verb
    # word is looked for right after the namespace, then at the end, then in between; read nouns only
    # when there is no verb word.
    VERB_WORDS = {
      "read" => { verb: "get", words: %w[GET GETS FIND LOOKUP SEARCH SRCH SELECT QUERY FETCH RETRIEVE] },
      "write" => { verb: "put", words: %w[SET UPDATE UPD EDIT FILE STORE PUT CHANGE MODIFY REPLACE] },
      "delete" => { verb: "delete", words: %w[DEL DELETE REMOVE PURGE KILL] },
      "act" => { verb: "post", words: %w[ADD NEW CREATE SAVE SEND VALIDATE VERIFY CHECK CHK SIGN QUEUE LOCK UNLOCK REGISTER
                                         UNREGISTER RUN PRINT CANCEL CLONE COPY IMPORT EXPORT UPLOAD NOTIFY ACKNOWLEDGE BUILD
                                         REFRESH CLEAR FLUSH START STOP CLOSE RENEW FORWARD] }
    }.freeze
    READ_NOUNS = %w[LIST LISTS LST REPORT REPORTS RPT INFO DETAIL DETAILS SUMMARY VIEW DISPLAY].freeze
    VERB_OF = VERB_WORDS.flat_map { |rule, v| v[:words].map { |w| [ w, { rule: rule, verb: v[:verb] } ] } }.to_h.freeze
    # Two RPCs of one package that share a verb and path move up a tier, each a little closer to the full
    # name, until none clash.
    TIERS = [ "base", "verb word kept", "namespace", "namespace and verb word" ].freeze

    module_function

    def slug(text)
      s = text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      s.empty? ? "unassigned" : s
    end

    # One word's verb, if it has one. Two fused forms are read words too: GET<thing> (GETCATS), whose
    # remainder stays in the path, and ALL<things> (ALLKEYS), kept whole; ALLERG* is not one.
    def verb_of(word)
      return VERB_OF[word].merge(word: word, keep: nil) if VERB_OF.key?(word)
      return { rule: "read", verb: "get", word: "GET<thing>", keep: word[3..] } if word.match?(/\AGET[A-Z0-9]/)
      return { rule: "read", verb: "get", word: "ALL<things>", keep: word } if word.start_with?("ALL") && !word.start_with?("ALLERG")

      nil
    end

    # The verb, the resource words and the namespace of one RPC name, before uniqueness (see addresses).
    def address(name)
      all = name.split(/ +/).reject(&:empty?)
      namespace = all.size > 1 ? all[0] : nil
      words = namespace ? all[1..] : all
      at = [ 0, words.size - 1, *words.each_index ].select { |i| i >= 0 }.uniq.find { |i| verb_of(words[i]) }
      if at
        v = verb_of(words[at])
        rest = words.each_with_index.flat_map { |w, i| i != at ? [ w ] : Array(v[:keep]) }
        # A name that is only a namespace and a verb (ORWDX SAVE) keeps the verb word: it is all there is.
        return { verb: v[:verb], verb_rule: "#{v[:rule]}: #{v[:word]}", words: rest.empty? ? [ words[at] ] : rest,
                 dropped: v[:keep] ? nil : words[at], namespace: namespace }
      end
      noun = words.reverse.find { |w| READ_NOUNS.include?(w) }
      return { verb: "get", verb_rule: "read noun: #{noun}", words: words, dropped: nil, namespace: namespace } if noun

      { verb: "post", verb_rule: "default: no verb word", words: words, dropped: nil, namespace: namespace }
    end

    # { name => { verb:, path:, verb_rule:, path_rule: } } for every RPC of one package, unique per verb.
    #   1 base                     /<package>/<resource words>
    #   2 verb word kept           /<package>/<resource words with the dropped verb word back, in place>
    #   3 namespace                /<package>/<namespace>/<resource words>
    #   4 namespace and verb word  /<package>/<namespace>/<every word after the namespace>
    def addresses(names, package_slug)
      list = names.map { |name| address(name).merge(name: name, tier: 0) }
      words = lambda do |x|
        next x[:words] unless x[:tier].odd? && x[:dropped]

        all = x[:name].split(/ +/).reject(&:empty?)
        x[:namespace] ? all[1..] : all
      end
      path_of = lambda do |x|
        "/" + [ package_slug, (slug(x[:namespace]) if x[:tier] >= 2 && x[:namespace]), slug(words.(x).join(" ")) ].compact.join("/")
      end
      loop do
        clashes = list.group_by { |x| "#{x[:verb]} #{path_of.(x)}" }.values.select { |xs| xs.size > 1 }
        break if clashes.empty?

        clashes.each do |xs|
          xs.each do |x|
            raise Refused, "#{xs.map { |y| y[:name] }.join(' and ')} share #{x[:verb].upcase} #{path_of.(x)} at every tier" if x[:tier] == TIERS.size - 1

            x[:tier] += 1
          end
        end
      end
      list.to_h { |x| [ x[:name], { verb: x[:verb], path: path_of.(x), verb_rule: x[:verb_rule], path_rule: TIERS[x[:tier]] } ] }
    end

    # The package of each RPC: the #9.4 PREFIX that is the longest prefix of its routine.
    def packages_by_prefix(packages)
      packages.reject { |p| p[:prefix].to_s.empty? }.each_with_index.sort_by { |p, i| [ -p[:prefix].length, i ] }.map(&:first)
    end

    def param_schema(param)
      type = PARAM_TYPES[param.type.to_s] || "LITERAL"
      schema = case type
      when "LIST" then { "type" => "object", "additionalProperties" => { "type" => "string" } }
      when "WORD PROCESSING" then { "type" => "array", "items" => { "type" => "string" } }
      else { "type" => "string" }
      end
      schema["maxLength"] = param.max_length.to_i if type == "LITERAL" && param.max_length.to_s.match?(/\A\d+\z/)
      schema
    end

    def text(lines) = lines.map(&:rstrip).join("\n").strip

    # x-position is the walk order; x-rpms-sequence is #8994's SEQUENCE NUMBER as stored, when it has one.
    # A name #8994 registers twice for one RPC keeps both: the repeat is keyed "<name> (2)", and
    # x-rpms-name holds the name as registered.
    def arguments(rpc, entry)
      props = {}
      required = []
      formals = rpc.formals.to_a.map(&:strip).reject(&:empty?)
      if rpc.params.to_a.any?
        rpc.params.each_with_index do |p, i|
          key = p.name
          n = 1
          key = "#{p.name} (#{n += 1})" while props.key?(key)
          desc = text(p.description)
          props[key] = OpenApi.compact(param_schema(p).merge(
            "description" => (desc unless desc.empty?), "x-position" => i + 1,
            "x-rpms-sequence" => (p.seq.to_i if p.seq.to_s.match?(/\A\d+\z/)), "x-rpms-name" => (p.name unless key == p.name),
            "x-rpms-param-type" => PARAM_TYPES[p.type.to_s] || p.type.to_s
          ))
          required << key if p.required
        end
        [ props, required, "8994" ]
      elsif formals.size > 1
        formals.drop(1).each_with_index do |formal, i|
          props[formal] = { "type" => "string", "x-position" => i + 1,
                            "description" => "From #{entry || 'the entry point'}'s formal list; #8994 defines no INPUT PARAMETER." }
        end
        [ props, required, "routine" ]
      else
        [ props, required, "none" ]
      end
    end

    def operation(rpc, pkg, addr)
      entry = rpc.entry_point
      props, required, source = arguments(rpc, entry)
      return_type = RETURN_TYPES[rpc.return_type.to_s] || rpc.return_type.to_s
      reply = [ "SINGLE VALUE", "GLOBAL INSTANCE" ].include?(return_type) ? { "type" => "string" } : { "type" => "array", "items" => { "type" => "string" } }
      ret = text(rpc.returns.to_a)
      desc = text(rpc.description.to_a)
      inactive = INACTIVE.fetch(rpc.inactive.to_s, rpc.inactive ? rpc.inactive.to_s : "ACTIVE")
      op = {
        "operationId" => rpc.name.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, ""),
        "summary" => rpc.name,
        "description" => desc.empty? ? "#8994 carries no description for #{rpc.name} (#{entry ? "entry point #{entry}" : 'no entry point'})." : desc,
        "tags" => [ pkg ? pkg[:name] : "UNASSIGNED" ],
        "responses" => { "200" => { "description" => ret.empty? ? return_type : ret, "content" => { MEDIA => { "schema" => reply } } } },
        "x-rpms" => OpenApi.compact(
          "rpc" => rpc.name, "entry_point" => entry, "routine" => rpc.routine.to_s, "tag" => rpc.tag.to_s,
          "routine_present" => rpc.routine_present, "tag_present" => rpc.tag_present,
          "formals" => rpc.formals.to_a.map(&:strip).reject(&:empty?),
          "return_value_type" => return_type, "availability" => AVAILABILITY[rpc.availability.to_s] || rpc.availability.to_s,
          "inactive" => inactive, "word_wrap" => rpc.word_wrap == "1", "version" => rpc.version, "params_source" => source,
          "package" => (pkg && { "prefix" => pkg[:prefix], "name" => pkg[:name], "version" => pkg[:version] }),
          "reach" => (rpc.reach && { "class" => rpc.reach, "contexts" => rpc.contexts, "exempt_on" => rpc.exempt_on }),
          "verb_rule" => addr[:verb_rule], "path_rule" => addr[:path_rule]
        )
      }
      op["deprecated"] = true unless LOCALLY_ACTIVE.include?(inactive)
      unless props.empty?
        op["requestBody"] = {
          "required" => required.any?,
          "content" => { MEDIA => { "schema" => OpenApi.compact("type" => "object", "properties" => props, "required" => (required if required.any?)) } }
        }
      end
      op
    end

    # The whole document for one build. surface: an RpmsRpc::Conformance::BuildSurface with reach and
    # signatures; build: the provenance of its files (OpenApi.build_provenance); gem: OpenApi.gem_provenance.
    def document(surface, build:, gem:)
      raise Refused, "#{surface.tag}: no rpc_reach.txt pinned" unless surface.reach?
      raise Refused, "#{surface.tag}: no rpc_signatures.txt pinned" unless surface.signatures?

      rpcs = surface.rpcs
      prefixes = packages_by_prefix(surface.packages)
      pkg_of = rpcs.to_h { |r| [ r.name, prefixes.find { |p| r.routine.to_s.start_with?(p[:prefix]) } ] }
      tag_of = ->(r) { pkg_of[r.name]&.dig(:name) || "UNASSIGNED" }
      addr = {}
      rpcs.group_by(&tag_of).each { |t, rs| addr.merge!(addresses(rs.map(&:name).sort, slug(t))) }
      items = rpcs.map { |r| [ addr[r.name], operation(r, pkg_of[r.name], addr[r.name]) ] }
      # Sorted by path, then by method in a fixed order, so the document diffs by RPC.
      items = items.each_with_index.sort_by { |(a, _), i| [ a[:path], METHODS.index(a[:verb]), i ] }.map(&:first)
      paths = {}
      items.each { |a, op| (paths[a[:path]] ||= {})[a[:verb]] = op }
      ops = items.map(&:last)
      used = OpenApi.tally(ops.map { |o| o["tags"][0] })
      {
        "openapi" => OpenApi::VERSION,
        "info" => {
          "title" => "RPMS RPC surface",
          # The RPMS version (bcer-9.0), not the build, so it holds still across builds; x-rpms-build names the build.
          "version" => surface.tag[/\Abcer-\d+(?:\.\d+)*/] || surface.tag,
          "description" => "Every RPC build #{surface.tag} registers in REMOTE PROCEDURE (#8994), with its arguments, its reply " \
                           "and, from the build's reach face, where it can be called from. Generated by rpms-rpc `rake openapi:surface` " \
                           "from the rpms-ops release inventory the gem pins. An RPC is not an HTTP endpoint: each operation is sent " \
                           "over the RPC broker (XWB, BMX or CIA) by name, its arguments in x-position order. The path and verb are " \
                           "derived from that name, to read it as a resource; the summary and x-rpms.rpc are the exact name the " \
                           "broker is sent. The x-rpms fields are documented in rpms-rpc docs/openapi.md."
        },
        # The broker, not HTTP: one templated server and no HTTP security. Sign-on happens on the broker
        # itself (XUS AV CODE on XWB/BMX, CIANBRPC AUTH on CIA); each RPC then runs under the contexts
        # x-rpms.reach names.
        "servers" => [ { "url" => "broker://{host}:{port}", "description" => "A running RPMS's RPC broker (XWB, BMX or CIA)",
                         "variables" => { "host" => { "default" => "localhost" }, "port" => { "default" => "9100" } } } ],
        "security" => [],
        "tags" => used.map { |t, n| { "name" => t, "description" => "#{n} RPC(s)" } },
        "paths" => paths,
        "x-rpms-gem" => gem,
        "x-rpms-build" => build,
        "x-rpms-counts" => {
          "rpcs" => ops.size,
          "verbs" => OpenApi.tally(items.map { |a, _| a[:verb].upcase }),
          "path_rules" => OpenApi.tally(ops.map { |o| o["x-rpms"]["path_rule"] }),
          "params_source" => OpenApi.tally(ops.map { |o| o["x-rpms"]["params_source"] }),
          # Arguments by where they came from; the "8994" count equals the walk's parameters=.
          "parameters" => ops.each_with_object({}) do |o, t|
            n = o.dig("requestBody", "content", MEDIA, "schema", "properties")&.size.to_i
            t[o["x-rpms"]["params_source"]] = t.fetch(o["x-rpms"]["params_source"], 0) + n if n.positive?
          end.sort.to_h,
          "reach" => surface.reach_counts
        }
      }
    end
  end
end
