# frozen_string_literal: true

require "json"
require "open3"

# The two OpenAPI documents rpms-rpc generates (rpms-rpc#395), and what they share: provenance, output and
# the checks every document passes. `rake openapi:surface` and `rake openapi:api` drive them; the fields
# are documented once, in docs/openapi.md. Lives under tools/ so it never ships in the gem.
#
#   OpenApi::Surface    the RPC surface of the pinned build      -> rpc-surface.openapi.json
#   OpenApi::ClientApi  the gem's public methods, as resources   -> client-api.openapi.json
#
# Both are deterministic: the same inputs (the pinned files, the gem's source, its commit) give
# byte-identical output. Nothing in them is a timestamp.
module OpenApi
  VERSION = "3.1.0"
  # The release asset names (fixed, so a consumer fetches them by the gem's release tag).
  SURFACE_FILE = "rpc-surface.openapi.json"
  API_FILE = "client-api.openapi.json"
  HTTP_METHODS = %w[get put post delete options head patch trace].freeze

  class Refused < StandardError; end

  module_function

  # The hash without its nil values (false, "" and [] stay).
  def compact(hash) = hash.reject { |_, v| v.nil? }

  # { value => count }, sorted by value.
  def tally(values) = values.tally.sort.to_h

  # The gem a document came from: its version and the commit of the checkout. GEM_COMMIT overrides the
  # commit (a CI checkout of a tag knows it); a checkout with uncommitted changes says so, since its
  # output is not the commit's.
  def gem_provenance(root, commit: ENV["GEM_COMMIT"])
    require_relative "../../lib/rpms_rpc/version"
    dirty = nil
    unless commit
      commit, ok = git(root, "rev-parse", "HEAD")
      raise Refused, "#{root} is not a git checkout: set GEM_COMMIT=<sha>" unless ok

      status, = git(root, "status", "--porcelain", "--untracked-files=no")
      dirty = true unless status.empty?
    end
    compact("name" => "rpms-rpc", "version" => RpmsRpc::VERSION, "commit" => commit, "dirty" => dirty)
  end

  def git(root, *args)
    out, status = Open3.capture2("git", "-C", root, *args)
    [ out.strip, status.success? ]
  end

  def pretty(document) = JSON.pretty_generate(document) + "\n"

  # Write DOCUMENT to PATH and prove it: the bytes on disk parse back to the same document.
  def write(document, path)
    require "fileutils"
    FileUtils.mkdir_p(File.dirname(path))
    text = pretty(document)
    File.write(path, text)
    raise Refused, "wrote #{path}, but it does not read back as the document" unless File.read(path) == text && JSON.parse(text) == document

    path
  end

  # [[verb, path, operation]] for every operation in a paths object.
  def operations(paths)
    paths.flat_map { |path, item| item.select { |verb, _| HTTP_METHODS.include?(verb) }.map { |verb, op| [ verb, path, op ] } }
  end

  # The checks every generated document passes, as a list of problems (empty = OK): OpenAPI 3.1, a
  # unique verb and path for every operation (path parameters compared by position, not name), unique
  # operationIds, every path parameter declared, and the provenance present.
  def problems(document)
    out = []
    out << "openapi is #{document['openapi'].inspect}, not #{VERSION}" unless document["openapi"] == VERSION
    out << "x-rpms-gem names no commit" if document.dig("x-rpms-gem", "commit").to_s.empty?
    out << "x-rpms-build names no build tag" if document.dig("x-rpms-build", "tag").to_s.empty?
    keys = Hash.new { |h, k| h[k] = [] }
    ids = Hash.new { |h, k| h[k] = [] }
    operations(document.fetch("paths", {})).each do |verb, path, op|
      keys["#{verb.upcase} #{path.gsub(/\{[^}]+\}/, '{}')}"] << "#{verb.upcase} #{path}"
      ids[op["operationId"]] << "#{verb.upcase} #{path}"
      templated = path.scan(/\{([^}]+)\}/).flatten
      declared = op.fetch("parameters", []).select { |p| p["in"] == "path" }.map { |p| p["name"] }
      out << "#{verb.upcase} #{path}: path parameters #{templated} are declared as #{declared}" unless templated.sort == declared.sort
    end
    keys.each { |k, at| out << "#{k} is #{at.size} operations: #{at.join(', ')}" if at.size > 1 }
    ids.each { |id, at| out << "operationId #{id.inspect} is used #{at.size} times: #{at.join(', ')}" if at.size > 1 }
    out
  end

  # The OpenAPI 3.1 schema's verdict on DOCUMENT (json_schemer, a development dependency), as a list of
  # problems (empty = valid).
  def schema_problems(document)
    require "json_schemer"
    JSONSchemer.openapi31_document.validate(document).first(10).map { |e| "#{e['data_pointer']}: #{e['error']}" }
  end
end
