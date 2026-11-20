# frozen_string_literal: true

# The RPC inventory: one row per RPC across one IRIS and one YottaDB openrpms release, with what rpms-rpc covers
# (wrappers, REST paths, read or write, live specs, captured replies, live verdicts) and which clients use it.
#
#   rake rpc:inventory [IRIS=<tag>] [YDB=<tag>] [OUT=tmp/rpc-inventory] [CACHE=tmp/openrpms]
#   rake rpc:inventory_tags [IRIS=<tag>] [YDB=<tag>]
#   rake rpc:inventory_notes RELEASE=<rpms-rpc tag> IRIS=<tag> YDB=<tag> CSV=<file> NOTES=<file>
#
# A tag defaults to the newest published (non-draft) release of that engine; pass both to pin the run. The
# release assets are downloaded with gh into CACHE/<tag>/ once. Writes OUT/rpc-inventory.csv and .md; commits
# nothing. Same tags, same checkout: the same bytes. The implementation lives in tools/rpc_inventory/.
#
# inventory_tags prints the pair the inventory would use as iris=<tag> and ydb=<tag> lines (a GitHub step output).
# inventory_notes writes RELEASE's notes with the inventory section in place (tools/rpc_inventory release_notes):
# the two tags, the command, and the columns against the previous release that carries the CSV. Both are how
# .github/workflows/rpc-inventory-release.yml attaches the inventory to an rpms-rpc release.
namespace :rpc do
  inventory_tool = lambda do
    root = File.expand_path("../..", __dir__)
    tool = File.join(root, "tools/rpc_inventory/rpc_inventory.rb")
    abort "rpc:inventory: needs a source checkout (#{tool} is not in the gem)" unless File.file?(tool)
    $LOAD_PATH.unshift(File.join(root, "lib"))
    require "rpms_rpc"
    require tool
    root
  end

  # { "iris" => tag, "ydb" => tag }: IRIS= and YDB= where given, else the newest published release of the engine.
  inventory_tags = lambda do
    tags = { "iris" => ENV["IRIS"], "ydb" => ENV["YDB"] }.reject { |_, v| v.to_s.empty? }
    tags.each do |engine, tag|
      m = RpcInventory::TAG.match(tag)
      abort "rpc:inventory: #{engine.upcase}=#{tag.inspect} is not an openrpms #{engine} release tag" unless m && m[:engine] == engine
    end
    tags = RpcInventory.latest_tags(RpcInventory.release_list).merge(tags) if tags.size < RpcInventory::ENGINES.size
    missing = RpcInventory::ENGINES - tags.keys
    abort "rpc:inventory: no published openrpms release for #{missing.join(', ')}" unless missing.empty?
    tags
  rescue RuntimeError, JSON::ParserError => e
    abort "rpc:inventory: #{e.message}"
  end

  desc "Write the RPC inventory (CSV + Markdown) for an IRIS and a YottaDB openrpms release (IRIS=, YDB= tags; OUT=)"
  task :inventory do
    root = inventory_tool.call
    tags = inventory_tags.call
    cache = File.expand_path(ENV["CACHE"] || "tmp/openrpms", root)
    out = File.expand_path(ENV["OUT"] || "tmp/rpc-inventory", root)
    begin
      releases = RpcInventory::ENGINES.map { |e| RpcInventory.load_release(RpcInventory.fetch(tags[e], cache), tags[e]) }
      files = RpcInventory.render(releases, root)
    rescue RuntimeError, JSON::ParserError, RpmsRpc::Error => e
      abort "rpc:inventory: #{e.message}"
    end

    FileUtils.mkdir_p(out)
    files.each do |name, body|
      path = File.join(out, name)
      File.write(path, body)
      abort "rpc:inventory: #{path} does not hold what was generated" unless File.read(path) == body
    end
    rows = files["rpc-inventory.csv"].count("\n") - 1
    puts "EXPLICIT SUCCESS: rpc:inventory wrote #{files.keys.map { |f| File.join(out, f).delete_prefix("#{root}/") }.join(' and ')}: " \
         "#{rows} RPCs, #{tags.values_at(*RpcInventory::ENGINES).join(' + ')}"
  end

  desc "Rewrite the inventory's client lists from their sources (CLOUD_RPMS=, OPENRPMS=, LAKERAVEN_EHR= checkouts; BPRM_XML= file)"
  task :inventory_clients do
    root = inventory_tool.call
    require File.join(root, "tools/rpc_inventory/clients")
    need = %w[CLOUD_RPMS OPENRPMS LAKERAVEN_EHR BPRM_XML].select { |k| ENV[k].to_s.empty? }
    abort "EXPLICIT FAILURE: rpc:inventory_clients: give #{need.join(', ')}; no snapshot was changed" unless need.empty?

    dir = ->(k) { File.expand_path(ENV.fetch(k)) }
    c = RpcInventory::Clients
    # Every file is built before any is written, so a missing or unreadable source leaves all four as they were.
    begin
      sending = RpcInventory.coverage(root, surface: nil)[:methods].reject { |m| m["rpcs"].empty? }
                            .map { |m| "#{m['module'].delete_prefix('RpmsRpc::')}.#{m['method']}" }
      files = {
        "vuecentric-observed.tsv" => c.observed(dir.("CLOUD_RPMS"), dir.("OPENRPMS")),
        "vuecentric-named.txt" => c.named(dir.("CLOUD_RPMS")),
        "lakeraven-ehr-methods.txt" => c.lakeraven_ehr(dir.("LAKERAVEN_EHR"), sending),
        "bprm-entry-points.txt" => c.bprm(dir.("BPRM_XML"))
      }
    rescue c::Error, SystemCallError, JSON::ParserError, EncodingError => e
      abort "EXPLICIT FAILURE: rpc:inventory_clients: #{e.message}; no snapshot was changed"
    end

    out = File.join(root, RpcInventory::CLIENT_DIR)
    files.each do |name, body|
      path = File.join(out, name)
      File.write(path, body)
      abort "EXPLICIT FAILURE: rpc:inventory_clients: #{path} does not hold what was generated" unless File.read(path) == body
    end
    rows = files.map { |name, body| "#{name} #{body.lines.count { |l| !l.start_with?('#') }}" }
    puts "EXPLICIT SUCCESS: rpc:inventory_clients wrote #{RpcInventory::CLIENT_DIR}/: #{rows.join(', ')} lines"
  end

  desc "Print the openrpms release pair rpc:inventory would use, as iris=<tag> and ydb=<tag> lines"
  task :inventory_tags do
    inventory_tool.call
    inventory_tags.call.each { |engine, tag| puts "#{engine}=#{tag}" }
  end

  desc "Write an rpms-rpc release's notes with the RPC inventory section (RELEASE=, IRIS=, YDB=, CSV=, NOTES=)"
  task :inventory_notes do
    inventory_tool.call
    need = %w[RELEASE IRIS YDB CSV NOTES].select { |k| ENV[k].to_s.empty? }
    abort "rpc:inventory_notes: give #{need.join(', ')}" unless need.empty?
    release = ENV.fetch("RELEASE")
    tags = inventory_tags.call
    repo = ENV["GITHUB_REPOSITORY"].to_s.empty? ? "lakeraven/rpms-rpc" : ENV["GITHUB_REPOSITORY"]
    gh = lambda do |*args|
      out, err, st = Open3.capture3("gh", *args)
      abort "rpc:inventory_notes: gh #{args.first(3).join(' ')} failed (#{err.lines.first.to_s.strip})" unless st.success?
      out
    end
    header = File.open(ENV.fetch("CSV"), &:gets).to_s
    abort "rpc:inventory_notes: #{ENV['CSV']} does not start with the inventory's header" unless header.chomp == RpcInventory::COLUMNS.join(",")

    list = JSON.parse(gh.call("api", "--paginate", "--slurp", "repos/#{repo}/releases")).flatten(1)
    abort "rpc:inventory_notes: #{repo} has no release #{release}" unless list.any? { |r| r["tag_name"] == release }
    prev = RpcInventory.previous_release(list, release)
    previous = prev && { tag: prev, header: gh.call("release", "download", prev, "-R", repo, "-p", "rpc-inventory.csv", "-O", "-").lines.first.to_s }
    body = JSON.parse(gh.call("release", "view", release, "-R", repo, "--json", "body"))["body"]
    notes = RpcInventory.splice_notes(body, RpcInventory.release_notes(tags, header, previous))
    File.write(ENV.fetch("NOTES"), notes)
    abort "rpc:inventory_notes: #{ENV['NOTES']} does not hold what was generated" unless File.read(ENV.fetch("NOTES")) == notes
    puts "EXPLICIT SUCCESS: rpc:inventory_notes wrote #{ENV['NOTES']} for #{release} (columns against #{prev || 'no earlier release'})"
  end
end
