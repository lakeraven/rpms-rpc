# frozen_string_literal: true

# The RPC inventory: one row per RPC across one IRIS and one YottaDB openrpms release, with what rpms-rpc covers
# (wrappers, REST paths, read or write, live specs, captured replies, live verdicts) and which clients use it.
#
#   rake rpc:inventory [IRIS=<tag>] [YDB=<tag>] [OUT=tmp/rpc-inventory] [CACHE=tmp/openrpms]
#
# A tag defaults to the newest published (non-draft) release of that engine; pass both to pin the run. The
# release assets are downloaded with gh into CACHE/<tag>/ once. Writes OUT/rpc-inventory.csv and .md; commits
# nothing. Same tags, same checkout: the same bytes. The implementation lives in tools/rpc_inventory/.
namespace :rpc do
  desc "Write the RPC inventory (CSV + Markdown) for an IRIS and a YottaDB openrpms release (IRIS=, YDB= tags; OUT=)"
  task :inventory do
    root = File.expand_path("../..", __dir__)
    tool = File.join(root, "tools/rpc_inventory/rpc_inventory.rb")
    abort "rpc:inventory: needs a source checkout (#{tool} is not in the gem)" unless File.file?(tool)
    $LOAD_PATH.unshift(File.join(root, "lib"))
    require "rpms_rpc"
    require tool

    tags = { "iris" => ENV["IRIS"], "ydb" => ENV["YDB"] }.reject { |_, v| v.to_s.empty? }
    tags.each do |engine, tag|
      m = RpcInventory::TAG.match(tag)
      abort "rpc:inventory: #{engine.upcase}=#{tag.inspect} is not an openrpms #{engine} release tag" unless m && m[:engine] == engine
    end
    cache = File.expand_path(ENV["CACHE"] || "tmp/openrpms", root)
    out = File.expand_path(ENV["OUT"] || "tmp/rpc-inventory", root)
    begin
      tags = RpcInventory.latest_tags(RpcInventory.release_list).merge(tags) if tags.size < RpcInventory::ENGINES.size
      missing = RpcInventory::ENGINES - tags.keys
      abort "rpc:inventory: no published openrpms release for #{missing.join(', ')}" unless missing.empty?

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
end
