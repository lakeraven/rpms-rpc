# frozen_string_literal: true

# The OpenAPI documents (rpms-rpc#395): the RPC surface of the openrpms release under test, and the gem's
# client API.
#
#   rake openapi:surface [OUT=pkg/openapi/rpc-surface.openapi.json]
#   rake openapi:api     [METHODS=<rake rpc:api_coverage JSON>] [OUT=pkg/openapi/client-api.openapi.json]
#   rake openapi         surface + api, into pkg/openapi/
#
# Both read the release `rake openrpms:fetch` recorded (tmp/openrpms/current.json; OPENRPMS_RELEASE=<tag> on
# the fetch names one, the default is the latest published -ydb release). Nothing is pinned in this repository
# (rpms-rpc#724): the surface reads that release's <tag>-rpcs.json (openrpms#732), the bytes the fetch checked
# against the release's asset digests (tools/openapi/release_surface.rb). The API document runs rpc:api_coverage's
# analysis in process on the same release, unless METHODS= names a file it wrote. Each document is checked
# before the task reports success (OpenAPI 3.1 schema, unique verb + path), and names the gem commit
# (GEM_COMMIT= overrides) and the build tag. Fields: docs/openapi.md.
# The release workflow (.github/workflows/openapi-release.yml) attaches both to the gem's GitHub release.
# The implementation lives in tools/openapi/, which is not part of the gem.
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

  desc "OpenAPI 3.1 document of every RPC the release under test registers, from its <tag>-rpcs.json (OUT= path; rake openrpms:fetch first)"
  task :surface do
    load_tool.("surface")
    load_tool.("release_surface")
    release = OpenApi::ReleaseSurface.read
    document = OpenApi::Surface.document(release[:surface], build: OpenApi::ReleaseSurface.build_provenance(release), gem: OpenApi.gem_provenance(root))
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
      # The client API is described on the same release as the surface, so the two documents name one build.
      load_tool.("release_surface")
      r = ApiCoverage.build(root, surface: OpenApi::ReleaseSurface.read[:surface])
      JSON.parse(JSON.generate(ApiCoverage.document(r[:entries], registry_tag: r[:registry_tag])))
    end
    document = OpenApi::ClientApi.document(methods, gem: OpenApi.gem_provenance(root))
    path = File.expand_path(ENV["OUT"] || File.join(out_dir, OpenApi::API_FILE), root)
    report.("openapi:api", document, path) { OpenApi.write(document, path) }
  rescue OpenApi::Refused => e
    abort "openapi:api: #{e.message}"
  end
end

desc "Both OpenAPI documents, into pkg/openapi/ (rake openapi:surface + openapi:api); they must name one build"
task openapi: %w[openapi:surface openapi:api] do
  require "json"
  dir = File.expand_path("../../pkg/openapi", __dir__)
  # Only meaningful for the default outputs: OUT= writes one task's document elsewhere.
  next puts "openapi: OUT= set; the build-tag check needs the default outputs" if ENV["OUT"]

  tags = %w[rpc-surface.openapi.json client-api.openapi.json].to_h { |f| [ f, JSON.parse(File.read(File.join(dir, f))).dig("x-rpms-build", "tag") ] }
  abort "openapi: the documents name different builds: #{tags} (both read the release openrpms:fetch recorded; rebuild both)" unless tags.values.uniq.size == 1
  puts "EXPLICIT SUCCESS: openapi: both documents name #{tags.values.first}"
end
