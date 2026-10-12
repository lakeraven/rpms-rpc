# frozen_string_literal: true

# The OpenAPI documents (rpms-rpc#395): the RPC surface of the pinned build, and the gem's client API.
#
#   rake openapi:surface [RELEASE=<pinned tag>] [OUT=pkg/openapi/rpc-surface.openapi.json]
#   rake openapi:api     [METHODS=<rake rpc:api_coverage JSON>] [OUT=pkg/openapi/client-api.openapi.json]
#   rake openapi         both, into pkg/openapi/
#
# The build is the pinned release data/rpc_coverage/config.yml names (the registry rpc:api_coverage
# checks against), so the two documents name the same build; RELEASE= picks another pinned tag. The
# surface reads the pinned files only after InventoryLock has verified them against the lock. The API
# document runs rpc:api_coverage's analysis in process unless METHODS= names a file it wrote. Each
# document is checked before the task reports success (OpenAPI 3.1 schema, unique verb + path), and
# names the gem commit (GEM_COMMIT= overrides) and the build tag. Fields: docs/openapi.md.
# The release workflow (.github/workflows/openapi-release.yml) attaches both to the gem's GitHub
# release. The implementation lives in tools/openapi/, which is not part of the gem.
namespace :openapi do
  root = File.expand_path("../..", __dir__)
  tool = File.join(root, "tools/openapi")
  out_dir = File.join(root, "pkg/openapi")

  load_tool = lambda do |name|
    abort "openapi: needs a source checkout (#{tool} is not in the gem)" unless File.directory?(tool)
    require File.join(tool, name)
  end

  # Prove the document before reporting it written: a silent failure here would publish a broken contract.
  report = lambda do |task, document, path, &write|
    problems = OpenApi.problems(document) + OpenApi.schema_problems(document)
    abort "#{task}: #{path} FAILS its checks:\n  #{problems.join("\n  ")}" unless problems.empty?

    write.call
    puts "  #{OpenApi.operations(document['paths']).size} operations, gem #{document.dig('x-rpms-gem', 'commit')[0, 12]}" \
         "#{' (dirty checkout)' if document.dig('x-rpms-gem', 'dirty')}, build #{document.dig('x-rpms-build', 'tag')}"
    puts "EXPLICIT SUCCESS: #{task} wrote #{path.delete_prefix("#{root}/")} (OpenAPI #{document['openapi']}, valid, every verb + path unique)"
  end

  desc "OpenAPI 3.1 document of every RPC the pinned build registers (RELEASE= pinned tag, OUT= path)"
  task :surface do
    load_tool.("surface")
    require "yaml"
    $LOAD_PATH.unshift(File.join(root, "lib"))
    require "rpms_rpc/conformance/inventory_lock"

    lock_class = RpmsRpc::Conformance::InventoryLock
    tag = ENV["RELEASE"] || YAML.safe_load_file(File.join(root, "data/rpc_coverage/config.yml")).fetch("release")
    lock = lock_class.load(File.join(root, "data/fingerprints", lock_class::DEFAULT_PATH))
    entry = lock[tag] or abort "openapi:surface: #{tag} is not pinned in data/fingerprints/rpms-ops.lock.yml (rake conformance:pin RELEASE=#{tag})"
    inventory = begin
      lock_class.verify_dir(tag, File.join(root, "data/inventories", tag))
    rescue lock_class::Error => e
      abort "openapi:surface: #{e.message}"
    end
    drift = (inventory.shas.keys | entry["assets"].to_h.keys).reject { |n| inventory.shas[n] == entry.dig("assets", n) }
    abort "openapi:surface: #{tag}'s committed files differ from the lock (#{drift.join(', ')}); rake conformance:check" unless drift.empty?

    document = OpenApi::Surface.document(inventory.surface, build: OpenApi.build_provenance(inventory), gem: OpenApi.gem_provenance(root))
    path = File.expand_path(ENV["OUT"] || File.join(out_dir, OpenApi::SURFACE_FILE), root)
    report.("openapi:surface", document, path) { OpenApi.write(document, path) }
  rescue OpenApi::Refused => e
    abort "openapi:surface: #{e.message}"
  end

  desc "OpenAPI 3.1 document of the gem's public methods as resources (METHODS= api_coverage JSON, OUT= path)"
  task :api do
    load_tool.("client_api")
    methods = if ENV["METHODS"]
      JSON.parse(File.read(File.expand_path(ENV["METHODS"], root)))
    else
      require File.join(root, "tools/api_coverage/api_coverage")
      $LOAD_PATH.unshift(File.join(root, "lib"))
      require "rpms_rpc"
      r = ApiCoverage.build(root)
      JSON.parse(JSON.generate(ApiCoverage.document(r[:entries], registry_tag: r[:registry_tag])))
    end
    document = OpenApi::ClientApi.document(methods, gem: OpenApi.gem_provenance(root))
    path = File.expand_path(ENV["OUT"] || File.join(out_dir, OpenApi::API_FILE), root)
    report.("openapi:api", document, path) { OpenApi.write(document, path) }
  rescue OpenApi::Refused => e
    abort "openapi:api: #{e.message}"
  end
end

desc "Both OpenAPI documents, into pkg/openapi/ (rake openapi:surface + openapi:api)"
task openapi: %w[openapi:surface openapi:api]
