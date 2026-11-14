# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "yaml"
require_relative "document"
require_relative "../../lib/rpms_rpc/conformance/build_surface"

module OpenApi
  # The one openrpms file the RPC surface document is generated from (rpms-rpc#395 AC 2): a build's
  # <tag>-rpcs.json (openrpms#732; schema rpcs.v1, or rpcs.v2 with #8994's text, openrpms#877), pinned by
  # tag and sha256 the way conformance:pin pins the raw inventory, with the schema its `schema` field names
  # fetched at that build's own openrpms commit. The release is read over REST (`gh api`, not GraphQL); the
  # header's commit may be short, and is resolved to the full commit the inventory lock already verified.
  #
  #   data/openapi/rpcs.lock.yml           what is pinned: tag, asset, sha256, the schema's name, source and sha256
  #   data/openapi/<tag>-rpcs.json         the release asset, byte for byte
  #   data/openapi/<schema>.schema.json    openrpms releases/schema/<schema>.schema.json at the build's commit
  #
  # `rake openapi:pin RELEASE=<tag>` writes all three; `verify` proves them offline before
  # `rake openapi:surface` reads anything. This pin depends on data/fingerprints/rpms-ops.lock.yml, whose
  # builds every conformance gate runs against (see docs/openapi.md, "Which build"): that lock gives the
  # full build commit and the sha256 of the asset, which the release's own digest must equal.
  module RpcsPin
    DIR = "data/openapi"
    LOCK = "#{DIR}/rpcs.lock.yml".freeze
    SCHEMAS = RpmsRpc::Conformance::BuildSurface::RPCS_SCHEMAS
    REPO = "lakeraven/openrpms"
    # The inventory lock written by `rake conformance:pin`: the verified full build commit per tag.
    INVENTORY_LOCK = "data/fingerprints/rpms-ops.lock.yml"

    module_function

    def sha256(path) = Digest::SHA256.file(path).hexdigest

    # Where schema NAME (rpcs.v1, rpcs.v2) is committed here, and where openrpms keeps it.
    def schema_file(name) = "#{DIR}/#{name}.schema.json"
    def schema_source_path(name) = "releases/schema/#{name}.schema.json"

    def lock(root)
      path = File.join(root, LOCK)
      raise Refused, "#{LOCK} not found: nothing pinned (rake openapi:pin RELEASE=<tag>)" unless File.file?(path)

      YAML.safe_load_file(path)
    end

    # The inventory lock as a Hash, read the way InventoryLock reads it (safe_load_file, Date permitted).
    # A missing lock, or one that is not the mapping conformance:pin writes, refuses.
    def inventory_lock(root, tag = "<tag>")
      path = File.join(root, INVENTORY_LOCK)
      raise Refused, "#{INVENTORY_LOCK} not found: run rake conformance:pin RELEASE=#{tag} first" unless File.file?(path)

      data = begin
        YAML.safe_load_file(path, permitted_classes: [ Date ])
      rescue Psych::Exception => e
        raise Refused, "#{INVENTORY_LOCK} is not readable YAML (#{e.class}): #{e.message}"
      end
      raise Refused, "#{INVENTORY_LOCK} is not a mapping: #{data.class}" unless data.is_a?(Hash)

      data
    end

    # The inventory lock's entry for TAG; an unpinned tag or a malformed `releases` refuses.
    def inventory_entry(tag, root)
      releases = inventory_lock(root, tag)["releases"]
      raise Refused, "#{INVENTORY_LOCK} releases is not a mapping: #{releases.class}" unless releases.is_a?(Hash)

      entry = releases[tag]
      raise Refused, "#{INVENTORY_LOCK} pins no #{tag}: run rake conformance:pin RELEASE=#{tag} first" unless entry.is_a?(Hash)

      entry
    end

    # The full build commit for a rpcs.json header's commit (7 to 40 hex, possibly abbreviated): the one
    # `rake conformance:pin` verified for TAG in the inventory lock. The header alone never names the commit
    # the schema is fetched at; absence or disagreement in the lock refuses.
    def build_commit(header_commit, tag:, root:)
      full = inventory_entry(tag, root)["build_commit"]
      raise Refused, "#{INVENTORY_LOCK} build_commit for #{tag} is not 40 lowercase hex: #{full.inspect}" unless full.is_a?(String) && full.match?(/\A[0-9a-f]{40}\z/)
      raise Refused, "rpcs.json header commit #{header_commit.inspect} is not 7 to 40 lowercase hex" unless header_commit.is_a?(String) && header_commit.match?(/\A[0-9a-f]{7,40}\z/)
      raise Refused, "rpcs.json header commit #{header_commit} is not a prefix of #{tag}'s pinned build commit #{full}" unless full.start_with?(header_commit)

      full
    end

    # The bare sha256 the inventory lock records for ASSET in TAG's release: the bytes conformance:pin
    # verified, which this pin must take too.
    def locked_asset_digest(asset, tag:, root:)
      assets = inventory_entry(tag, root)["assets"]
      raise Refused, "#{INVENTORY_LOCK} assets for #{tag} is not a mapping: #{assets.class}" unless assets.is_a?(Hash)

      digest = assets[asset]
      raise Refused, "#{INVENTORY_LOCK} records no sha256 for #{asset} in #{tag}: #{digest.inspect}" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)

      digest
    end

    # The id and bare sha256 of ASSET in RELEASE (the REST JSON of releases/tags/<tag>). Only a published
    # release counts, and the digest GitHub computed is the only thing the download is checked against.
    def release_asset(release, asset)
      raise Refused, "release for #{asset} is not a JSON object: #{release.class}" unless release.is_a?(Hash)
      raise Refused, "release for #{asset} is a draft (draft is #{release['draft'].inspect}): only published releases are pinned" unless release["draft"] == false
      raise Refused, "release for #{asset} is a prerelease (prerelease is #{release['prerelease'].inspect}): only published releases are pinned" unless release["prerelease"] == false
      raise Refused, "release assets for #{asset} is not a list: #{release['assets'].class}" unless release["assets"].is_a?(Array)

      found = release["assets"].find { |a| a.is_a?(Hash) && a["name"] == asset }
      raise Refused, "release publishes no #{asset} (released before openrpms#732?)" unless found
      raise Refused, "#{asset} has no usable asset id: #{found['id'].inspect}" unless found["id"].is_a?(Integer) && found["id"].positive?

      digest = found["digest"]
      raise Refused, "#{asset} has no sha256 digest in the release: #{digest.inspect}" unless digest.is_a?(String) && digest.match?(/\Asha256:[0-9a-f]{64}\z/)

      { id: found["id"], digest: digest.delete_prefix("sha256:") }
    end

    # The pinned schema's verdict on DOC, as a list of problems (empty = valid). The schema is closed.
    def schema_problems(doc, schema_path)
      require "json_schemer"
      JSONSchemer.schema(JSON.parse(File.read(schema_path))).validate(doc).first(10).map { |e| "#{e['data_pointer']}: #{e['error']}" }
    end

    # Prove the pin offline and read it: the committed file is the pinned sha256, the schema is the
    # pinned one, the file's schema field is the pinned schema's name (rpcs.v1 or rpcs.v2), it validates
    # against that schema, and its
    # header names the pinned tag. Returns { tag:, path:, sha256:, doc:, surface: }.
    def verify(root)
      l = lock(root)
      tag = l.fetch("tag")
      path = File.join(root, DIR, l.fetch("asset"))
      name = l.fetch("schema")
      raise Refused, "#{LOCK} pins schema #{name.inspect}, not one of #{SCHEMAS.join(', ')}" unless SCHEMAS.include?(name)

      schema = File.join(root, schema_file(name))
      raise Refused, "#{l['asset']} is not committed under #{DIR}/" unless File.file?(path)
      raise Refused, "#{l['asset']} sha256 #{sha256(path)} is not the pinned #{l['sha256']}" unless sha256(path) == l["sha256"]
      raise Refused, "#{schema_file(name)} sha256 #{File.file?(schema) ? sha256(schema) : 'missing'} is not the pinned #{l['schema_sha256']}" unless File.file?(schema) && sha256(schema) == l["schema_sha256"]

      doc = JSON.parse(File.read(path, encoding: "UTF-8"))
      raise Refused, "#{l['asset']} has schema #{doc['schema'].inspect}, not the pinned #{name}" unless doc["schema"] == name

      problems = schema_problems(doc, schema)
      raise Refused, "#{l['asset']} does not validate against #{schema_file(name)}:\n  #{problems.join("\n  ")}" unless problems.empty?

      surface = RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path, tag: tag)
      { tag: tag, path: path, sha256: l["sha256"], doc: doc, surface: surface }
    rescue RpmsRpc::Conformance::BuildSurface::Error => e
      raise Refused, e.message
    end

    # The build a surface document came from: the rpcs.json header, and the file itself.
    def build_provenance(pin)
      d = pin[:doc]
      {
        "tag" => d["tag"], "rpms_version" => d["rpms_version"], "engine" => d["engine"], "rpms_ops_commit" => d["commit"],
        "source" => { "file" => File.basename(pin[:path]), "sha256" => pin[:sha256], "schema" => d["schema"] },
        # The raw files openrpms projected it from, as its header names them.
        "inputs" => d["inputs"].map { |file, sha| { "file" => "#{d['tag']}-#{file}", "sha256" => sha } }
      }
    end
  end
end
