# frozen_string_literal: true

require "digest"
require "json"
require "yaml"
require_relative "document"
require_relative "../../lib/rpms_rpc/conformance/build_surface"

module OpenApi
  # The one rpms-ops file the RPC surface document is generated from (rpms-rpc#395 AC 2): a build's
  # <tag>-rpcs.json (rpms-ops#732; schema rpcs.v1, or rpcs.v2 with #8994's text, rpms-ops#877), pinned by
  # tag and sha256 the way conformance:pin pins the raw inventory, with the schema its `schema` field names
  # fetched at that build's own rpms-ops commit.
  #
  #   data/openapi/rpcs.lock.yml           what is pinned: tag, asset, sha256, the schema's name, source and sha256
  #   data/openapi/<tag>-rpcs.json         the release asset, byte for byte
  #   data/openapi/<schema>.schema.json    rpms-ops releases/schema/<schema>.schema.json at the build's commit
  #
  # `rake openapi:pin RELEASE=<tag>` writes all three; `verify` proves them offline before
  # `rake openapi:surface` reads anything. This pin is separate from data/fingerprints/rpms-ops.lock.yml,
  # whose builds every conformance gate runs against (see docs/openapi.md, "Which build").
  module RpcsPin
    DIR = "data/openapi"
    LOCK = "#{DIR}/rpcs.lock.yml".freeze
    SCHEMAS = RpmsRpc::Conformance::BuildSurface::RPCS_SCHEMAS
    REPO = "lakeraven/rpms-ops"

    module_function

    def sha256(path) = Digest::SHA256.file(path).hexdigest

    # Where schema NAME (rpcs.v1, rpcs.v2) is committed here, and where rpms-ops keeps it.
    def schema_file(name) = "#{DIR}/#{name}.schema.json"
    def schema_source_path(name) = "releases/schema/#{name}.schema.json"

    def lock(root)
      path = File.join(root, LOCK)
      raise Refused, "#{LOCK} not found: nothing pinned (rake openapi:pin RELEASE=<tag>)" unless File.file?(path)

      YAML.safe_load_file(path)
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
        # The raw files rpms-ops projected it from, as its header names them.
        "inputs" => d["inputs"].map { |file, sha| { "file" => "#{d['tag']}-#{file}", "sha256" => sha } }
      }
    end
  end
end
