# frozen_string_literal: true

# The OpenAPI documents (rpms-rpc#395): the RPC surface of a pinned build, and the gem's client API.
#
#   rake openapi:pin     RELEASE=<rpms-ops tag>   pin that release's <tag>-rpcs.json (and the schema it names)
#   rake openapi:surface [OUT=pkg/openapi/rpc-surface.openapi.json]
#   rake openapi:api     [METHODS=<rake rpc:api_coverage JSON>] [OUT=pkg/openapi/client-api.openapi.json]
#   rake openapi         surface + api, into pkg/openapi/
#
# The surface reads ONE rpms-ops file, the pinned <tag>-rpcs.json (rpms-ops#732), and only after it is
# proven offline: its sha256 is the pin's, its schema field (rpcs.v1 or rpcs.v2) is the pinned schema's,
# and it validates against that schema (tools/openapi/rpcs_pin.rb). The API document runs rpc:api_coverage's analysis in process
# unless METHODS= names a file it wrote; its build is the one data/rpc_coverage/config.yml names. Each
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

  desc "Pin a release's <tag>-rpcs.json for openapi:surface: RELEASE=<rpms-ops tag> [REPO=lakeraven/rpms-ops]. " \
       "Downloads it, checks it against the release asset digest, fetches the rpms-ops schema its `schema` field " \
       "names (rpcs.v1, rpcs.v2) at the build's commit, validates, and writes data/openapi/rpcs.lock.yml."
  task :pin do
    load_tool.("rpcs_pin")
    require "fileutils"
    require "open3"
    require "tmpdir"
    pin = OpenApi::RpcsPin
    tag = ENV["RELEASE"] or abort "openapi:pin requires RELEASE=<rpms-ops release tag>"
    abort "refusing RELEASE with unsafe characters: #{tag.inspect}" unless tag.match?(/\A[A-Za-z0-9._-]+\z/)
    repo = ENV["REPO"] || pin::REPO
    asset = "#{tag}-rpcs.json"

    out, status = Open3.capture2("gh", "release", "view", tag, "--repo", repo, "--json", "assets")
    abort "openapi:pin: gh release view failed for #{tag} on #{repo} (published? gh auth?)" unless status.success?
    digest = JSON.parse(out)["assets"].find { |a| a["name"] == asset }&.dig("digest").to_s.delete_prefix("sha256:")
    abort "openapi:pin: #{tag} publishes no #{asset} (released before rpms-ops#732?)" if digest.empty?

    Dir.mktmpdir do |tmp|
      ok = system("gh", "release", "download", tag, "--repo", repo, "--pattern", asset, "--dir", tmp)
      abort "openapi:pin: gh release download of #{asset} failed" unless ok
      file = File.join(tmp, asset)
      abort "openapi:pin: #{asset} sha256 #{pin.sha256(file)} is not the release asset digest #{digest}" unless pin.sha256(file) == digest

      header = JSON.parse(File.read(file))
      commit = header["commit"].to_s
      name = header["schema"].to_s
      abort "openapi:pin: #{asset} names no build commit" unless commit.match?(/\A[0-9a-f]{40}\z/)
      abort "openapi:pin: #{asset} has schema #{name.inspect}, not one of #{pin::SCHEMAS.join(', ')}" unless pin::SCHEMAS.include?(name)

      # The schema the file names, at the commit that built it: what rpms-ops validated it against.
      source = pin.schema_source_path(name)
      schema, status = Open3.capture2("gh", "api", "-H", "Accept: application/vnd.github.raw", "repos/#{repo}/contents/#{source}?ref=#{commit}")
      abort "openapi:pin: cannot fetch #{source} at #{repo}@#{commit}" unless status.success? && !schema.empty?

      dir = File.join(root, pin::DIR)
      FileUtils.mkdir_p(dir)
      old = File.file?(File.join(root, pin::LOCK)) ? pin.lock(root)["asset"] : nil
      FileUtils.rm_f(File.join(dir, old)) if old && old != asset
      Dir[File.join(dir, "*.schema.json")].each { |f| FileUtils.rm_f(f) }
      FileUtils.cp(file, File.join(dir, asset))
      File.write(File.join(root, pin.schema_file(name)), schema)
      lock = { "repo" => repo, "tag" => tag, "asset" => asset, "sha256" => digest, "schema" => name,
               "schema_source" => "#{repo}@#{commit}:#{source}", "schema_sha256" => pin.sha256(File.join(root, pin.schema_file(name))) }
      File.write(File.join(root, pin::LOCK),
                 "# The rpms-ops build whose <tag>-rpcs.json `rake openapi:surface` reads (rpms-rpc#395) - written by\n" \
                 "# `rake openapi:pin`; do not hand-edit. test/openapi/pinned_documents_test.rb checks the bytes against it.\n" +
                 YAML.dump(lock))
    end
    verified = pin.verify(root)
    puts "EXPLICIT SUCCESS: pinned #{asset} (#{verified[:surface].names.size} RPCs, sha256 #{verified[:sha256]}, " \
         "valid #{verified[:doc]['schema']}); commit #{pin::DIR}/"
  rescue OpenApi::Refused => e
    abort "openapi:pin: #{e.message}"
  end

  desc "OpenAPI 3.1 document of every RPC the pinned build registers, from its <tag>-rpcs.json (OUT= path)"
  task :surface do
    load_tool.("surface")
    load_tool.("rpcs_pin")
    pin = OpenApi::RpcsPin.verify(root)
    document = OpenApi::Surface.document(pin[:surface], build: OpenApi::RpcsPin.build_provenance(pin), gem: OpenApi.gem_provenance(root))
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
