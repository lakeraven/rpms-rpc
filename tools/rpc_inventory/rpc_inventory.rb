# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "zlib"
require_relative "../openrpms_matrix"
require_relative "../api_coverage/api_coverage"
require_relative "../openapi/surface"
require_relative "../openapi/client_api"

# The RPC inventory: one row per RPC across one IRIS and one YottaDB openrpms release, with what rpms-rpc covers.
#
#   rake rpc:inventory [IRIS=<tag>] [YDB=<tag>] [OUT=tmp/rpc-inventory]
#
# It joins what already exists and adds no source of its own:
#   the releases    each engine's <tag>-rpcs.json (#8994 with reach classes and contexts; BuildSurface reads it),
#                   <tag>-rpms-rpc-live.json (the per-RPC verdict of rpms-rpc's live run), its two
#                   <tag>-conformance-<persona>.jsonl wire-case records and <tag>-harness.json (which rpms-rpc
#                   judged it). A tag defaults to the newest published (non-draft) release of that engine.
#   rpms-rpc        tools/api_coverage (which public methods send each RPC, which live specs call them), its
#                   captured-reply fixtures, retry_safety.yml (read or write), and the openapi:api and
#                   openapi:surface addressing (the wrapper's REST verb and path, and the RPC name's own address)
#   the clients     data/rpc_inventory/clients/ (VueCentric named and observed, BPRM, lakeraven-ehr) and
#                   data/rpc_tiers/observed/ (a recorded VueCentric session)
#
# Same inputs, same bytes: rows are byte-sorted by RPC name, every list in a cell is sorted, and nothing reads a
# clock. The output is not committed (tmp/ is ignored): it is a view of published releases, like openrpms:matrix.
# Lives under tools/ so it never ships in the gem.
module RpcInventory
  OPENRPMS = OpenrpmsMatrix::OPENRPMS
  TAG = OpenrpmsMatrix::TAG
  ENGINES = %w[iris ydb].freeze
  PERSONAS = %w[least_privilege programmer].freeze
  CLIENT_DIR = "data/rpc_inventory/clients"
  OBSERVED_DIR = "data/rpc_tiers/observed"

  COLUMNS = %w[
    rpc package_prefix package
    registered_iris registered_ydb reach_iris reach_ydb contexts entry_point
    vuecentric bprm lakeraven_ehr
    wrappers wrapper_paths rpc_path resource operation operation_source read_write
    live_tests captured_replies
    live_iris live_ydb wire_cases_iris wire_cases_ydb
  ].freeze

  # What each column holds, for the Markdown legend.
  LEGEND = {
    "rpc" => "the #8994 NAME, or a name a wrapper sends that neither release registers",
    "package_prefix, package" => "the #9.4 package openrpms assigned the RPC (longest PREFIX of its routine)",
    "registered_*" => "yes when that release's #8994 lists it",
    "reach_*" => "that release's reach class (client-callable and broker-exempt are callable)",
    "contexts" => "the #19 broker options whose RPC multiple lists it; one value when the engines agree, else `iris: ...; ydb: ...`",
    "entry_point" => "TAG^ROUTINE, the same way",
    "vuecentric" => "`observed` when a recorded VueCentric session called it, `named` when only the client's binaries name it",
    "bprm" => "`entry-point` when a BPRM stored procedure calls its entry point in process (BPRM sends no RPC)",
    "lakeraven_ehr" => "`yes` when a gem method lakeraven-ehr calls sends it",
    "wrappers" => "the rpms-rpc public methods that send it (tools/api_coverage)",
    "wrapper_paths" => "each wrapper's REST verb and path in the client API document (rake openapi:api)",
    "rpc_path" => "the RPC's own address in the RPC surface document (rake openapi:surface), derived from its name",
    "resource" => "what it acts on: the wrappers' paths without their parameters; else the FileMan files its #8994 DESCRIPTION cites",
    "operation" => "list, get, create, update, delete, status-change or other",
    "operation_source" => "`wrapper` (the wrappers' method names and verbs) or `name` (the RPC name's verb word); blank when neither says",
    "read_write" => "`read` when a wrapper retry_safety.yml classes read sends it, `write` when every wrapper is a write, else blank",
    "live_tests" => "the test/live/ files that call a wrapper",
    "captured_replies" => "the test fixtures holding a reply captured for it (test/fixtures/captured_replies, wire_captures)",
    "live_*" => "the release's <tag>-rpms-rpc-live.json, the gate's run of rpms-rpc's live read catalogue (tools/rpc_coverage): " \
                "pass, fail, known-failure, excluded, or not-run when the record does not cover it",
    "wire_cases_*" => "openrpms' wire cases for it, per persona: the verdict, `!` when that was not the expected one"
  }.freeze

  Release = Struct.new(:tag, :engine, :surface, :live, :cases, :harness, keyword_init: true)

  module_function

  # --- the releases ---------------------------------------------------------------------------

  def asset_names(tag)
    [ "#{tag}-rpcs.json", "#{tag}-rpms-rpc-live.json", "#{tag}-harness.json",
      *PERSONAS.map { |p| "#{tag}-conformance-#{p}.jsonl" } ]
  end

  # { "iris" => tag, "ydb" => tag }: per engine, the newest published release (not a draft or prerelease) that
  # carries a <tag>-rpcs.json, by published_at. list: the GitHub releases list.
  def latest_tags(list)
    picked = Array(list).select do |r|
      r.is_a?(Hash) && r["draft"] == false && r["prerelease"] == false && TAG.match?(r["tag_name"].to_s) &&
        Array(r["assets"]).any? { |a| a["name"] == "#{r['tag_name']}-rpcs.json" }
    end
    ENGINES.to_h do |e|
      newest = picked.select { |r| TAG.match(r["tag_name"])[:engine] == e }.max_by { |r| [ r["published_at"].to_s, r["tag_name"] ] }
      [ e, newest&.fetch("tag_name") ]
    end.compact
  end

  def release_list
    out, err, st = Open3.capture3("gh", "api", "--paginate", "--slurp", "repos/#{OPENRPMS}/releases")
    raise "cannot list #{OPENRPMS} releases (#{err.to_s.lines.first.to_s.strip}); a token that can read it is needed" unless st.success?

    JSON.parse(out).flatten(1)
  end

  # Downloads into dir/<tag>/ whichever of the tag's assets are not there yet; returns that dir.
  def fetch(tag, dir)
    raise "refusing tag #{tag.inspect}: not an openrpms release tag" unless TAG.match?(tag)

    into = File.join(dir, tag)
    FileUtils.mkdir_p(into)
    missing = asset_names(tag).reject { |n| File.file?(File.join(into, n)) || File.file?(File.join(into, "#{n}.gz")) }
    return into if missing.empty?

    args = [ "gh", "release", "download", tag, "-R", OPENRPMS, "-D", into, *missing.flat_map { |n| [ "-p", n ] } ]
    _, err, st = Open3.capture3(*args)
    raise "cannot download #{missing.join(', ')} from #{OPENRPMS} #{tag} (#{err.to_s.lines.first.to_s.strip})" unless st.success?

    gone = missing.reject { |n| File.file?(File.join(into, n)) }
    raise "#{tag} does not carry #{gone.join(', ')}" unless gone.empty?

    into
  end

  def read_maybe_gz(path)
    return File.read(path, encoding: "UTF-8") if File.file?(path)
    return Zlib::GzipReader.open("#{path}.gz") { |z| z.read.force_encoding("UTF-8") } if File.file?("#{path}.gz")

    nil
  end

  # One release from dir, where its assets sit under their published names (<tag>-rpcs.json may be gzipped).
  def load_release(dir, tag)
    engine = TAG.match(tag)&.[](:engine) or raise "#{tag} is not an openrpms release tag"
    rpcs_path = File.join(dir, "#{tag}-rpcs.json")
    text = read_maybe_gz(rpcs_path) or raise "#{tag}-rpcs.json is not in #{dir}"
    doc = JSON.parse(text)
    raise "#{File.basename(rpcs_path)} names tag #{doc['tag'].inspect}" unless doc["tag"] == tag

    surface = RpmsRpc::Conformance::BuildSurface.new(doc: doc, path: rpcs_path)
    live = read_maybe_gz(File.join(dir, "#{tag}-rpms-rpc-live.json"))
    harness = read_maybe_gz(File.join(dir, "#{tag}-harness.json"))
    cases = PERSONAS.to_h do |p|
      body = read_maybe_gz(File.join(dir, "#{tag}-conformance-#{p}.jsonl"))
      [ p, body ? body.lines.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) } : [] ]
    end
    Release.new(tag: tag, engine: engine, surface: surface, live: live && JSON.parse(live),
                cases: cases, harness: harness && JSON.parse(harness))
  end

  # --- rpms-rpc and the clients ---------------------------------------------------------------

  # What rpms-rpc covers, from a source checkout at root with lib/rpms_rpc loaded.
  def coverage(root)
    report = ApiCoverage.build(root)
    doc = JSON.parse(JSON.generate(ApiCoverage.document(report[:entries], registry_tag: report[:registry_tag])))
    { methods: doc["methods"], paths: wrapper_addresses(doc), replies: ApiCoverage.captured_replies(root),
      retry: RpmsRpc::RetrySafety.table.transform_values(&:to_s) }
  end

  # { "Module.method" => { verb:, path:, rule: } }: where the client API document places each method. A method the
  # catalog folds into another query sits at that query's address; one it excludes (no RPC, unresolved, or an
  # unregistered RPC) at the address inference gives it.
  def wrapper_addresses(doc)
    placed = OpenApi::ClientApi.catalog(doc)[:entries].to_h { |e| [ "#{e[:method]['module']}.#{e[:method]['method']}", e[:addr] ] }
    doc["methods"].to_h do |m|
      key = "#{m['module']}.#{m['method']}"
      a = placed[key] || OpenApi::ClientApi.address(m)
      [ key, { verb: a[:verb].upcase, path: a[:path], rule: a[:rule] } ]
    end
  end

  def names_in(path)
    return [] unless File.file?(path)

    File.readlines(path, chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
  end

  # { vuecentric_named:, vuecentric_observed:, bprm:, lakeraven_ehr_methods: } as sorted name lists.
  def clients(root)
    dir = File.join(root, CLIENT_DIR)
    observed = names_in(File.join(dir, "vuecentric-observed.txt"))
    Dir[File.join(root, OBSERVED_DIR, "*.tsv")].sort.each do |f|
      observed.concat(File.readlines(f, chomp: true).drop(1).map { |l| l.split("\t").first.to_s.strip }.reject(&:empty?))
    end
    {
      vuecentric_named: names_in(File.join(dir, "vuecentric-named.txt")).uniq.sort,
      vuecentric_observed: observed.uniq.sort,
      bprm: names_in(File.join(dir, "bprm.txt")).uniq.sort,
      lakeraven_ehr_methods: names_in(File.join(dir, "lakeraven-ehr-methods.txt")).map { |m| m.delete_prefix("RpmsRpc::") }.uniq.sort
    }
  end

  # --- derivations ----------------------------------------------------------------------------

  # The RPC name's own verb word (OpenApi::Surface.address) as an operation; nil when the name has none.
  NAME_LIST_WORDS = %w[FIND LOOKUP SEARCH SRCH SELECT QUERY ALL<things>].freeze
  NAME_CREATE_WORDS = %w[ADD NEW CREATE SAVE REGISTER].freeze
  NAME_STATUS_WORDS = %w[SIGN CANCEL LOCK UNLOCK CLOSE RENEW FORWARD START STOP UNREGISTER ACKNOWLEDGE].freeze
  NAME_LIST_NOUNS = %w[LIST LISTS LST].freeze

  def name_operation(name)
    rule = OpenApi::Surface.address(name)[:verb_rule]
    kind, word = rule.split(": ", 2)
    case kind
    when "read" then NAME_LIST_WORDS.include?(word) ? "list" : "get"
    when "read noun" then NAME_LIST_NOUNS.include?(word) ? "list" : "get"
    when "write" then "update"
    when "delete" then "delete"
    when "act"
      if NAME_CREATE_WORDS.include?(word) then "create"
      elsif NAME_STATUS_WORDS.include?(word) then "status-change"
      else "other"
      end
    end
  end

  METHOD_STATUS_WORDS = %w[cancel checkin complete inactivate lock mark sign uncancel unlock].freeze
  METHOD_LIST_WORDS = %w[list lister].freeze

  # One public method's operation, from its name's verb class (OpenApi::ClientApi.classify) and its path.
  def method_operation(method_name, path)
    c = OpenApi::ClientApi.classify(method_name)
    case c[:kind]
    when "query" then "list"
    when "create" then "create"
    when "write" then "update"
    when "delete" then "delete"
    when "action" then METHOD_STATUS_WORDS.include?(c[:verb_word]) ? "status-change" : "other"
    when "inquiry" then "get"
    else
      plural = method_name.sub(/[?!=]\z/, "").end_with?("s")
      # A read or a noun: one member (the path ends in its identifier, or a predicate) is a get; a list word, a
      # _for_<x> scope or a plural name is a list; any other read of a single thing is a get.
      if c[:predicate] || path.end_with?("}") then "get"
      elsif METHOD_LIST_WORDS.include?(c[:verb_word]) || c[:for_word] || plural then "list"
      else "get"
      end
    end
  end

  def resource_of_path(path) = path.split("/").reject { |s| s.empty? || s.start_with?("{") }.join("/")

  FILE_CITE = /\bfile\s*(?:#|no\.?|number)?\s*\(?#?\s*(\d+(?:\.\d+)?)\)?/i

  def cited_files(rpc)
    return [] unless rpc

    rpc.description.join(" ").scan(FILE_CITE).flatten.uniq.sort_by { |n| [ n.to_f, n ] }
  end

  # One value when every engine that has it agrees, else "iris: a; ydb: b".
  def agree(by_engine)
    present = by_engine.compact
    return "" if present.empty?
    return present.values.first if present.values.uniq.size == 1

    present.map { |e, v| "#{e}: #{v}" }.join("; ")
  end

  def live_cells(release)
    record = release.live
    return {} unless record.is_a?(Hash) && record["rpcs"].is_a?(Hash)

    OpenrpmsMatrix.cells(record).transform_values { |c| c["verdict"] }
  end

  # { rpc => "least_privilege=answered;programmer=answered" }, a "!" after a verdict that was not the expected one.
  def wire_cells(release)
    by_rpc = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
    release.cases.each do |persona, cases|
      cases.each { |c| by_rpc[c["rpc"]][persona] << "#{c['verdict']}#{'!' unless c['pass']}" }
    end
    by_rpc.transform_values do |per|
      per.sort.map { |persona, vs| "#{persona}=#{vs.uniq.sort.join('/')}" }.join(";")
    end
  end

  # --- the rows -------------------------------------------------------------------------------

  def rows(releases, cov, cli)
    by_engine = releases.to_h { |r| [ r.engine, r ] }
    senders = Hash.new { |h, k| h[k] = [] }
    cov[:methods].each do |m|
      key = "#{m['module'].delete_prefix('RpmsRpc::')}.#{m['method']}"
      m["rpcs"].each { |r| senders[r["name"]] << m.merge("key" => key, "full" => "#{m['module']}.#{m['method']}") }
    end
    lre = cli[:lakeraven_ehr_methods]
    live = by_engine.transform_values { |r| live_cells(r) }
    wire = by_engine.transform_values { |r| wire_cells(r) }
    addr = by_engine.transform_values do |r|
      r.surface.rpcs.group_by { |x| x.package&.dig(:name) || "UNASSIGNED" }.each_with_object({}) do |(pkg, rs), out|
        out.merge!(OpenApi::Surface.addresses(rs.map(&:name).sort, OpenApi::Surface.slug(pkg)))
      end
    end
    named = cli[:vuecentric_named].to_h { |n| [ n, true ] }
    observed = cli[:vuecentric_observed].to_h { |n| [ n, true ] }
    bprm = cli[:bprm].to_h { |n| [ n, true ] }

    names = (by_engine.values.flat_map { |r| r.surface.names } + senders.keys).uniq.sort_by(&:b)
    names.map do |name|
      rpc = ENGINES.to_h { |e| [ e, by_engine[e]&.surface&.[](name) ] }
      any = rpc.values.compact.first
      ms = senders.fetch(name, []).sort_by { |m| m["key"] }
      paths = ms.map { |m| cov[:paths][m["full"]] }
      ops = ms.zip(paths).map { |m, a| method_operation(m["method"], a[:path]) }.uniq.sort
      classes = ms.map { |m| cov[:retry][m["full"]] }
      rw = if classes.include?("read") then "read"
      elsif classes.any? && classes.all? { |c| c&.end_with?("write") } then "write"
      else ""
      end
      resources = paths.map { |a| resource_of_path(a[:path]) }.reject(&:empty?).uniq.sort
      resources = cited_files(any).map { |n| "FileMan ##{n}" } if resources.empty?
      name_op = name_operation(name)
      operation, source = if ops.any? then [ ops.join(";"), "wrapper" ]
      elsif name_op then [ name_op, "name" ]
      else [ "", "" ]
      end
      row = {
        "rpc" => name,
        "package_prefix" => any&.package&.dig(:prefix).to_s,
        "package" => any&.package&.dig(:name).to_s,
        "contexts" => agree(rpc.compact.transform_values { |r| r.contexts.sort.join("; ") }),
        "entry_point" => agree(rpc.compact.transform_values { |r| r.entry_point.to_s }),
        "vuecentric" => if observed[name] then "observed" elsif named[name] then "named" else "" end,
        "bprm" => bprm[name] ? "entry-point" : "",
        "lakeraven_ehr" => ms.any? { |m| lre.include?(m["key"]) } ? "yes" : "",
        "wrappers" => ms.map { |m| m["key"] }.join("; "),
        "wrapper_paths" => paths.map { |a| "#{a[:verb]} #{a[:path]}" }.uniq.join("; "),
        "rpc_path" => agree(addr.to_h { |e, a| [ e, a[name] && "#{a[name][:verb].upcase} #{a[name][:path]}" ] }),
        "resource" => resources.join("; "),
        "operation" => operation,
        "operation_source" => source,
        "read_write" => rw,
        "live_tests" => ms.flat_map { |m| m["live_specs"].map { |s| s.sub(/:\d+\z/, "") } }.uniq.sort.join("; "),
        "captured_replies" => cov[:replies].fetch(name, []).join("; ")
      }
      ENGINES.each do |e|
        r = rpc[e]
        here = by_engine.key?(e)
        row["registered_#{e}"] = here ? (r ? "yes" : "no") : ""
        row["reach_#{e}"] = r&.reach.to_s
        row["live_#{e}"] = live.dig(e, name) || (r ? "not-run" : "")
        row["wire_cases_#{e}"] = wire.dig(e, name).to_s
      end
      COLUMNS.to_h { |c| [ c, row.fetch(c) ] }
    end
  end

  # --- the summary ----------------------------------------------------------------------------

  def differences(releases)
    by = releases.to_h { |r| [ r.engine, r.surface ] }
    iris, ydb = by.values_at("iris", "ydb")
    return {} unless iris && ydb

    both = (iris.names & ydb.names).sort_by(&:b)
    diff = lambda do |&field|
      both.filter_map { |n| a, b = field.(iris[n]), field.(ydb[n]); [ n, a, b ] if a != b }
    end
    {
      iris_only: (iris.names - ydb.names).sort_by(&:b),
      ydb_only: (ydb.names - iris.names).sort_by(&:b),
      reach: diff.call(&:reach),
      contexts: diff.call { |r| r.contexts.sort },
      entry_point: diff.call(&:entry_point),
      formals: diff.call(&:formals)
    }
  end

  def client_used?(row) = !row["vuecentric"].empty? || !row["bprm"].empty? || !row["lakeraven_ehr"].empty?

  def summary(rows, releases)
    registered = rows.select { |r| ENGINES.any? { |e| r["registered_#{e}"] == "yes" } }
    unwrapped = registered.select { |r| r["wrappers"].empty? }
    {
      registered: ENGINES.to_h { |e| [ e, rows.count { |r| r["registered_#{e}"] == "yes" } ] },
      callable: ENGINES.to_h { |e| [ e, rows.count { |r| %w[client-callable broker-exempt].include?(r["reach_#{e}"]) } ] },
      differences: differences(releases),
      unregistered_sent: rows.reject { |r| ENGINES.any? { |e| r["registered_#{e}"] == "yes" } }.map { |r| r["rpc"] },
      wrapped: registered.count { |r| !r["wrappers"].empty? },
      live_tested: registered.count { |r| !r["live_tests"].empty? },
      captured: registered.count { |r| !r["captured_replies"].empty? },
      live: ENGINES.to_h { |e| [ e, rows.map { |r| r["live_#{e}"] }.reject(&:empty?).tally.sort.to_h ] },
      unwrapped_client: unwrapped.count { |r| client_used?(r) },
      unwrapped_no_client: unwrapped.count { |r| !client_used?(r) },
      unwrapped_observed: unwrapped.select { |r| r["vuecentric"] == "observed" }.map { |r| r["rpc"] },
      unwrapped_by_client: {
        "VueCentric observed" => unwrapped.count { |r| r["vuecentric"] == "observed" },
        "VueCentric named only" => unwrapped.count { |r| r["vuecentric"] == "named" },
        "BPRM entry point" => unwrapped.count { |r| !r["bprm"].empty? }
      },
      # An RPC whose wrappers do several operations counts once, as "several".
      operations: registered.map { |r| r["operation"].empty? ? "none derivable" : (r["operation"].include?(";") ? "several" : r["operation"]) }
                            .tally.sort_by { |k, v| [ -v, k ] }.to_h,
      read_write: registered.map { |r| r["read_write"] }.reject(&:empty?).tally.sort.to_h,
      harness: releases.to_h { |r| [ r.engine, r.harness&.dig("harness", "rpms_rpc_commit").to_s[0, 12] ] }
    }
  end

  # --- rendering ------------------------------------------------------------------------------

  def csv_field(v)
    s = v.to_s
    s.match?(/[",\n\r]/) ? "\"#{s.gsub('"', '""')}\"" : s
  end

  def csv(rows)
    ([ COLUMNS ] + rows.map { |r| COLUMNS.map { |c| r[c] } }).map { |f| f.map { |v| csv_field(v) }.join(",") }.join("\n") + "\n"
  end

  def md_cell(v) = v.to_s.gsub("|", "\\|").gsub("\n", " ")

  def list_or_none(names) = names.empty? ? "none" : names.map { |n| "`#{n}`" }.join(", ")

  def markdown(rows, releases)
    s = summary(rows, releases)
    d = s[:differences]
    tags = releases.sort_by(&:engine).map { |r| "`#{r.tag}`" }.join(" and ")
    same = d.empty? || d.values.all?(&:empty?)
    lines = []
    lines << "# RPC inventory"
    lines << ""
    lines << "Every RPC registered on #{tags}, one row per RPC, with what rpms-rpc covers."
    lines << "Generated by `rake rpc:inventory` (tools/rpc_inventory); the same inputs give the same bytes."
    lines << ""
    lines << "## Summary"
    lines << ""
    lines << "| | #{releases.sort_by(&:engine).map(&:engine).join(' | ')} |"
    lines << "|---|#{releases.map { '---:' }.join('|')}|"
    lines << "| registered (#8994) | #{releases.sort_by(&:engine).map { |r| s[:registered][r.engine] }.join(' | ')} |"
    lines << "| callable (client-callable or broker-exempt) | #{releases.sort_by(&:engine).map { |r| s[:callable][r.engine] }.join(' | ')} |"
    lines << "| live record judged by rpms-rpc | #{releases.sort_by(&:engine).map { |r| s[:harness][r.engine] }.join(' | ')} |"
    lines << ""
    unless d.empty?
      lines << "**Between the engines:** #{same ? 'the same RPCs, reach classes, contexts, entry points and formals.' : 'the differences are listed here.'}"
      lines << ""
      lines << "- IRIS only: #{list_or_none(d[:iris_only])}"
      lines << "- YottaDB only: #{list_or_none(d[:ydb_only])}"
      { reach: "reach class", contexts: "contexts", entry_point: "entry point", formals: "entry-point formals" }.each do |k, label|
        next lines << "- #{label} differs: none" if d[k].empty?

        lines << "- #{label} differs on #{d[k].size}:"
        d[k].each do |n, a, b|
          fmt = ->(v) { v.is_a?(Array) ? "#{v.size} (#{v.first(4).join(', ')}#{', ...' if v.size > 4})" : v.to_s }
          lines << "  - `#{n}`: IRIS #{fmt.(a)}; YottaDB #{fmt.(b)}"
        end
      end
      lines << ""
    end
    total = rows.count { |r| ENGINES.any? { |e| r["registered_#{e}"] == "yes" } }
    lines << "**rpms-rpc covers**, of the #{total} RPCs registered on either engine:"
    lines << ""
    lines << "- #{s[:wrapped]} are sent by a public method (wrapped); #{s[:live_tested]} by a method a live spec calls; #{s[:captured]} have a captured reply a unit test replays."
    lines << "- #{s[:wrapped] - s[:live_tested]} wrapped RPCs have no live spec."
    lines << "- Uncovered (no wrapper): #{s[:unwrapped_client]} used by a client, #{s[:unwrapped_no_client]} not " \
             "(#{s[:unwrapped_by_client].map { |k, v| "#{k} #{v}" }.join(', ')})."
    lines << "- Sent by a wrapper but registered on neither engine: #{list_or_none(s[:unregistered_sent])}."
    lines << "- Live verdicts: #{s[:live].map { |e, t| "#{e} #{t.map { |k, v| "#{k} #{v}" }.join(', ')}" }.join('; ')}."
    lines << "- Read or write (wrapped RPCs): #{s[:read_write].map { |k, v| "#{k} #{v}" }.join(', ')}."
    lines << "- Operations: #{s[:operations].map { |k, v| "#{k} #{v}" }.join(', ')}."
    lines << ""
    lines << "**VueCentric calls these in a recorded session, and no wrapper sends them** (#{s[:unwrapped_observed].size}): #{list_or_none(s[:unwrapped_observed])}."
    lines << ""
    lines << "## Columns"
    lines << ""
    LEGEND.each { |k, v| lines << "- `#{k}`: #{v}" }
    lines << ""
    lines << "## RPCs"
    lines << ""
    lines << "| #{COLUMNS.join(' | ')} |"
    lines << "|#{COLUMNS.map { '---' }.join('|')}|"
    rows.each { |r| lines << "| #{COLUMNS.map { |c| md_cell(r[c]) }.join(' | ')} |" }
    "#{lines.join("\n")}\n"
  end

  # Both files for releases (each a Release) and a source checkout at root: { "rpc-inventory.csv" =>, ".md" => }.
  # cov: coverage(root), when the caller already has it (the analysis of lib/ takes seconds).
  def render(releases, root, cov: coverage(root))
    rs = rows(releases, cov, clients(root))
    { "rpc-inventory.csv" => csv(rs), "rpc-inventory.md" => markdown(rs, releases) }
  end
end
