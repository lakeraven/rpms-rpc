# frozen_string_literal: true

require_relative "document"

module OpenApi
  # The gem's public methods as a resource-oriented HTTP API, OpenAPI 3.1 (rpms-rpc#395): what a web
  # client, or a host's HTTP facade over the gem, would call. Generated from `rake rpc:api_coverage`'s
  # document (#358); ported from rpms-ux bin/api-catalog.mjs. Each operation is one public method that a
  # registered RPC backs; the RPC names are evidence (x-rpms.rpcs), not the address. The mapping rules
  # are applied the same way to every method, nothing is curated per method; they are in docs/openapi.md.
  #
  # One document, with one tag per collection (/patients, /users, ...): modules that share a collection
  # share its tag, so a viewer groups them as rpms-ux's per-collection documents did.
  module ClientApi
    # Each module's collection, and the identifier params that name one of its own members (besides
    # `ien`). The one table here: a module name does not always say its resource (Adt is admissions,
    # Scheduling is appointments), so each is written down once.
    RESOURCES = {
      "Adt" => { path: "admissions" },
      "Agg" => { path: "agg" },
      "Allergy" => { path: "allergies" },
      "Authentication" => { path: "users", own: %w[duz user_duz] },
      "BehavioralHealth" => { path: "behavioral-health" },
      "BehavioralHealth::CaseManagement" => { path: "behavioral-health/cases" },
      "BehavioralHealth::Groups" => { path: "behavioral-health/groups" },
      "BehavioralHealth::Intake" => { path: "behavioral-health/intakes" },
      "BehavioralHealth::Reference" => { path: "behavioral-health" },
      "DdrFileman" => { path: "files", own: %w[file] },
      "ESignature" => { path: "signatures" },
      "Eligibility" => { path: "eligibility" },
      "Encounter" => { path: "encounters", own: %w[visit_ien] },
      "ExamComponent" => { path: "exam-components" },
      "HealthFactor" => { path: "health-factors" },
      "HealthSummary" => { path: "health-summaries" },
      "Image" => { path: "images" },
      "Immunization" => { path: "immunizations" },
      "ImmunizationRefusal" => { path: "immunization-refusals" },
      "Location" => { path: "locations" },
      "Measurement" => { path: "measurements" },
      "Medication" => { path: "medications" },
      "NoteTemplate" => { path: "note-templates" },
      "Notifications" => { path: "notifications" },
      "Order" => { path: "orders" },
      "Organization" => { path: "organizations" },
      "Patient" => { path: "patients", own: %w[dfn patient_dfn] },
      "Phr" => { path: "phr" },
      "Pov" => { path: "purposes-of-visit" },
      "Practitioner" => { path: "practitioners" },
      "Problem" => { path: "problems" },
      "Procedure" => { path: "procedures" },
      "ProgressNote" => { path: "progress-notes", own: %w[note_ien] },
      "Referral" => { path: "referrals" },
      "Registration" => { path: "registrations" },
      "Reminders" => { path: "reminders" },
      "Scheduling" => { path: "appointments" },
      "Session" => { path: "sessions" },
      "Site" => { path: "sites" },
      "Symptom" => { path: "symptoms" },
      "Tribal" => { path: "tribes" },
      "UserManagement" => { path: "users", own: %w[duz user_duz] },
      "Vital" => { path: "vitals" }
    }.freeze

    # The verb, from the method name's first word.
    VERBS = {
      "read" => %w[find get gets fetch list lister show detail details], # GET, word dropped
      "query" => %w[search lookup], # GET the collection, arguments as query parameters (and find_by_<x>)
      "inquiry" => %w[check which can is has authorize bootstrap], # GET, word kept: a read named like an action
      "create" => %w[add create new record register], # POST to the collection
      "write" => %w[update set file filer change], # PUT
      "delete" => %w[delete remove], # DELETE
      "action" => %w[authenticate cancel checkin complete generate inactivate init lock mark open print sign uncancel
                     unlock validate verify] # POST .../<action>
    }.freeze
    VERB_OF = { "read" => "get", "query" => "get", "inquiry" => "get", "noun" => "get", "create" => "post", "write" => "put",
                "delete" => "delete", "action" => "post" }.freeze
    DROPPED = %w[detail details].freeze # read nouns that add nothing to an item's path
    # Identifier params that always name the same collection, wherever they appear.
    PARENTS = { "dfn" => "patients", "patient_dfn" => "patients", "duz" => "users", "user_duz" => "users",
                "note_ien" => "progress-notes", "file" => "files", "iens" => "entries" }.freeze
    # Collections a path may start with, ahead of the module's own (a patient's problems, a user's sites).
    SCOPES = %w[patients users progress-notes].freeze
    VERB_ORDER = %w[get put post delete].freeze
    # Which query keeps the collection when two would: search, then lookup, then find_by_<x>.
    QUERY_RANK = { "search" => 0, "lookup" => 1, "find_by" => 2 }.freeze
    PROVEN = "proven"

    module_function

    def short(mod) = mod.delete_prefix("RpmsRpc::")

    def plural(word)
      return "#{word[0..-2]}ies" if word.match?(/[^aeiou]y\z/)
      return "#{word}es" if word.match?(/(s|x|ch|sh)\z/)

      "#{word}s"
    end

    def singular(word)
      return "#{word[0..-4]}y" if word.end_with?("ies")
      return word[0..-3] if word.match?(/(ss|x|ch|sh)es\z/)
      return word[0..-2] if word.end_with?("s")

      word
    end

    def id_name?(name) = PARENTS.key?(name) || name == "ien" || name.end_with?("_ien")

    # The verb class of a method name's words, and the words left for the path.
    def classify(name)
      words = name.sub(/[?!=]\z/, "").split("_").reject(&:empty?)
      for_word = nil
      rest = words
      if (at = words.index("for"))
        for_word = words[at + 1]
        rest = words[0...at]
      end
      return { kind: "noun", rest: rest, for_word: for_word, predicate: true } if name.end_with?("?")
      # find_by_<x>: a query whose remaining words name its parameter, so the path drops them.
      return { kind: "query", verb_word: "find_by", rest: [], sub_rest: rest.drop(1), for_word: for_word } if rest[0] == "find" && rest[1] == "by"

      VERBS.each do |kind, list|
        next unless rest.any? && list.include?(rest[0])
        return { kind: kind, verb_word: rest[0], rest: rest.drop(1), sub_rest: rest, for_word: for_word } if kind == "query"

        return { kind: kind, verb_word: rest[0], rest: kind == "inquiry" ? rest : rest.drop(1), for_word: for_word }
      end
      { kind: "noun", rest: rest, for_word: for_word }
    end

    def resource_of(mod)
      RESOURCES[mod] || { path: plural(mod.split("::").last.gsub(/([a-z])([A-Z])/, '\1-\2').downcase) }
    end

    # The collection a module belongs to: the first segment of its path (behavioral-health/cases is behavioral-health).
    def collection_of_module(mod) = resource_of(mod)[:path].split("/").first

    # Where a method lives: its verb, its path, and which params the path carries. A query (search,
    # lookup, find_by_<x>) also carries :sub, the sub-path it falls back to when another query has the
    # collection: catalog decides.
    def address(method)
      c = classify(method["method"])
      a = place(method, c, c[:rest])
      return a unless c[:kind] == "query"

      a.merge(rank: QUERY_RANK[c[:verb_word]], sub: place(method, c, c[:sub_rest]).merge(rule: "query-sub-path"))
    end

    def place(method, c, words)
      res = resource_of(short(method["module"]))
      base = res[:path].split("/")
      last = base.last
      own = [ "ien", *res[:own] ]
      verb = VERB_OF.fetch(c[:kind])
      rest = words.dup
      params = method["params"]

      # Identifier params: required positional ones, and required keywords; a user is one only as the first argument.
      ids = params.each_with_index.select do |p, i|
        %w[req keyreq].include?(p["kind"]) && id_name?(p["name"]) && !(%w[duz user_duz].include?(p["name"]) && i.positive?)
      end.map(&:first)
      collection_of = lambda do |p|
        next { coll: last, own: true, words: [] } if own.include?(p["name"])

        parent = PARENTS[p["name"]]
        next { coll: parent, own: parent == last, words: [ singular(parent) ] } if parent

        x = p["name"].delete_suffix("_ien")
        i = rest.index(x)
        named = i ? rest[0..i] : [ x ]
        coll = [ *named[0..-2], plural(x) ].join("-")
        is_own = coll == last || last.end_with?("-#{coll}")
        { coll: is_own ? last : coll, own: is_own, words: named }
      end

      segs = []
      path_params = []
      scope = nil
      if ids.any?
        first = collection_of.(ids[0])
        if !first[:own] && (SCOPES.include?(first[:coll]) || c[:for_word])
          scope = first.merge(param: ids[0])
          segs.push(first[:coll], "{#{ids[0]['name']}}")
          path_params << ids[0]["name"]
        end
      end
      segs.concat(base)
      # A create posts to the collection: identifiers other than the scope travel in the body.
      unless c[:kind] == "create"
        ids.each do |p|
          next if scope && p.equal?(scope[:param])

          col = collection_of.(p)
          col[:own] ? segs.push("{#{p['name']}}") : segs.push(col[:coll], "{#{p['name']}}")
          path_params << p["name"]
          rest -= col[:words]
        end
      end
      # Drop the words the path already says: the scope's member, the collection itself, and read nouns like "detail".
      said = [ last, singular(last), *(scope ? scope[:words] : []) ]
      rest = rest.reject { |w| said.include?(w) || DROPPED.include?(w) }
      rest = [ c[:verb_word], *rest ] if c[:kind] == "action"
      segs << rest.join("-") if rest.any?
      rule = if c[:predicate] then "predicate"
      elsif c[:for_word] && c[:kind] == "noun" then "for"
      else c[:kind]
      end
      { verb: verb, path: "/#{segs.join('/')}", path_params: path_params, rule: rule }
    end

    def ruby_call(method)
      args = method["params"].map do |p|
        { "req" => p["name"], "opt" => "#{p['name']} = ...", "rest" => "*#{p['name']}", "keyreq" => "#{p['name']}:",
          "key" => "#{p['name']}: ...", "keyrest" => "**#{p['name']}" }.fetch(p["kind"], p["name"])
      end
      "#{method['module']}.#{method['method']}(#{args.join(', ')})"
    end

    def operation(method, addr, collection)
      in_path = addr[:path_params]
      others = method["params"].reject { |p| in_path.include?(p["name"]) || p["name"].start_with?("_") }
      parameters = in_path.map { |n| { "name" => n, "in" => "path", "required" => true, "schema" => { "type" => "string" } } }
      arg_desc = ->(p) { "Ruby #{p['kind']} argument of #{method['method']}" }
      request_body = nil
      if %w[get delete].include?(addr[:verb])
        others.each do |p|
          multi = %w[rest keyrest].include?(p["kind"])
          param = { "name" => p["name"], "in" => "query", "required" => %w[req keyreq].include?(p["kind"]), "description" => arg_desc.(p),
                    "schema" => multi ? { "type" => "object", "additionalProperties" => true } : {} }
          param.merge!("style" => "form", "explode" => true) if multi
          parameters << param
        end
      elsif others.any?
        required = others.select { |p| %w[req keyreq].include?(p["kind"]) }.map { |p| p["name"] }
        schema = { "type" => "object", "properties" => others.to_h { |p| [ p["name"], { "description" => arg_desc.(p) } ] } }
        schema["required"] = required if required.any?
        request_body = { "required" => required.any?, "content" => { "application/json" => { "schema" => schema } } }
      end
      rpcs = method["rpcs"].map { |r| "`#{r['name']}` (#{r['entry_point']})" }.join(", ")
      specs = method["live_specs"].empty? ? "none" : method["live_specs"].map { |s| "`#{s}`" }.join(", ")
      status = method["status"] == PROVEN ? "Proven by a live spec" : "Not in the live contract"
      op = {
        "operationId" => "#{short(method['module'])}.#{method['method']}",
        "summary" => ruby_call(method),
        "description" => [ "Backed by #{rpcs}.", "Live specs: #{specs}.", "#{status}." ].join("\n\n"),
        "tags" => [ "/#{collection}" ]
      }
      op["parameters"] = parameters if parameters.any?
      op["requestBody"] = request_body if request_body
      op.merge(
        "responses" => { "200" => { "description" => "What #{ruby_call(method)} returns." } },
        "x-rpms" => {
          "ruby" => ruby_call(method),
          "rpcs" => method["rpcs"].map { |r| { "name" => r["name"], "registered" => r["registered"], "entry_point" => r["entry_point"], "reach" => r["reach"], "via" => r["via"] } },
          "status" => method["status"],
          "live_specs" => method["live_specs"],
          "personas" => method["personas"],
          "rule" => addr[:rule]
        }
      )
    end

    # The same query under a second name: its arguments join the first's as optional query parameters.
    def fold(op, method, addr, collection)
      have = op.fetch("parameters", []).map { |p| p["name"] }
      operation(method, addr, collection).fetch("parameters", []).each do |p|
        (op["parameters"] ||= []) << p.merge("required" => false) if p["in"] == "query" && !have.include?(p["name"])
      end
      op["x-rpms"]["folded"] = [ *op["x-rpms"]["folded"], "#{short(method['module'])}.#{method['method']}" ]
    end

    # { excluded:, entries: } from a parsed api_coverage document; entries are { method:, addr:, op:,
    # collection: }. Raises Refused on any clash. Queries are placed last, best rank first, so a plain read
    # of the collection keeps it and the first query takes it next; a later query on the same verb + path
    # is folded in when it is the same query (same module, same RPCs), and otherwise keeps its sub-path.
    def catalog(input)
      raise Refused, "api_coverage schema #{input['schema'].inspect}, expected 1" unless input["schema"] == 1

      excluded = { "no_rpc" => [], "unresolved" => [], "unregistered" => [] }
      key_of = ->(a) { "#{a[:verb].upcase} #{a[:path].gsub(/\{[^}]+\}/, '{}')}" }
      rpc_set = ->(m) { m["rpcs"].map { |r| r["name"] }.sort.join("|") }
      placed = []
      input["methods"].sort_by { |m| [ m["module"], m["method"] ] }.each do |m|
        id = "#{short(m['module'])}.#{m['method']}"
        next excluded["unresolved"] << id if m["unresolved"].to_a.any?
        next excluded["unregistered"] << id if m["rpcs"].any? { |r| !r["registered"] }
        next excluded["no_rpc"] << id if m["rpcs"].empty?

        placed << { method: m, id: id, addr: address(m) }
      end
      seen = {}
      entries = []
      placed.each_with_index.sort_by { |e, i| [ e[:addr][:sub] ? 1 + e[:addr][:rank] : 0, i ] }.map(&:first).each do |e|
        m = e[:method]
        a = e[:addr]
        collection = collection_of_module(short(m["module"]))
        held = seen[key_of.(a)]
        if held && a[:sub]
          if held[:method]["module"] == m["module"] && held[:addr][:sub] && rpc_set.(held[:method]) == rpc_set.(m)
            fold(held[:op], m, a, collection)
            next
          end
          a = a[:sub]
        end
        key = key_of.(a)
        raise Refused, "#{e[:id]} and #{seen[key][:op]['operationId']} are both #{key}" if seen.key?(key)

        entry = { method: m, addr: a, op: operation(m, a, collection), collection: collection }
        seen[key] = entry
        entries << entry
      end
      { excluded: excluded, entries: entries }
    end

    # The document, from a parsed api_coverage document (`rake rpc:api_coverage`'s JSON).
    def document(input, gem:)
      cat = catalog(input)
      entries = cat[:entries]
      sorted = entries.each_with_index.sort_by { |e, i| [ e[:addr][:path], VERB_ORDER.index(e[:addr][:verb]), i ] }.map(&:first)
      paths = {}
      sorted.each { |e| (paths[e[:addr][:path]] ||= {})[e[:addr][:verb]] = e[:op] }
      proven = ->(es) { es.count { |e| e[:method]["status"] == PROVEN } }
      collections = entries.group_by { |e| e[:collection] }.sort.map do |coll, es|
        { "name" => coll, "base" => "/#{coll}", "modules" => es.map { |e| e[:method]["module"] }.uniq.sort,
          "operations" => es.size, "proven" => proven.(es) }
      end
      verbs = entries.map { |e| e[:addr][:verb].upcase }.tally
      {
        "openapi" => OpenApi::VERSION,
        "info" => {
          "title" => "rpms-rpc client API",
          "version" => gem.fetch("version"),
          "description" => "The rpms-rpc gem's public methods, each addressed as a resource: what a web client, or a host's HTTP " \
                           "facade over the gem, would call. The summary is the Ruby call; x-rpms.rpcs are the registered RPCs it " \
                           "sends over the broker, on build #{input['registry']}; x-rpms.status says whether a live spec proves it. " \
                           "#{entries.size} operation(s), #{proven.(entries)} proven. Generated by rpms-rpc `rake openapi:api` from " \
                           "`rake rpc:api_coverage`. The x-rpms fields are documented in rpms-rpc docs/openapi.md."
        },
        "servers" => [ { "url" => "/", "description" => "A host's HTTP facade over the rpms-rpc gem" } ],
        "tags" => collections.map do |c|
          { "name" => c["base"], "description" => "#{c['base']}, from #{c['modules'].join(', ')}: #{c['operations']} operation(s), " \
                                                   "#{c['proven']} proven by a live spec." }
        end,
        "paths" => paths,
        "x-rpms-gem" => gem,
        "x-rpms-build" => { "tag" => input["registry"] },
        "x-rpms-api" => {
          "methods" => input["methods"].size,
          "operations" => entries.size,
          "proven" => proven.(entries),
          "verbs" => VERB_ORDER.to_h { |v| [ v.upcase, verbs.fetch(v.upcase, 0) ] },
          "excluded" => cat[:excluded],
          "folded" => entries.flat_map { |e| e[:op]["x-rpms"].fetch("folded", []) }.sort,
          "collections" => collections
        }
      }
    end
  end
end
