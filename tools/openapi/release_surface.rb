# frozen_string_literal: true

require_relative "document"
require_relative "../../lib/rpms_rpc/conformance/release_inventory"

module OpenApi
  # The one openrpms file the RPC surface document is generated from (rpms-rpc#395 AC 2): the <tag>-rpcs.json
  # of the release under test (openrpms#732; schema rpcs.v1, rpcs.v2 with #8994's text, openrpms#877, or rpcs.v3, openrpms#1359).
  #
  # Nothing is pinned here (rpms-rpc#724). `rake openrpms:fetch` downloads the release into tmp/openrpms/<tag>/,
  # checks every byte against the release's asset digests and the sidecar, and records it in current.json;
  # this reads those same verified bytes back, offline, through ReleaseInventory.current. OPENRPMS_RELEASE=<tag>
  # on the fetch names a release; the default is the latest published -ydb one.
  module ReleaseSurface
    module_function

    # The surface of INVENTORY (a verified ReleaseInventory::Inventory; default the one ROOT/current.json names,
    # verified again). Returns { tag:, path:, sha256:, doc:, surface: }. Refused when nothing was fetched or the
    # files no longer verify.
    def read(inventory = nil, root: RpmsRpc::Conformance::ReleaseInventory.cache_root)
      inventory ||= RpmsRpc::Conformance::ReleaseInventory.current(root: root)
      path = inventory.rpcs_json
      doc = JSON.parse(File.read(path, encoding: "UTF-8"))
      { tag: inventory.tag, path: path, sha256: inventory.shas.fetch(File.basename(path)), doc: doc, surface: inventory.surface }
    rescue RpmsRpc::Conformance::ReleaseInventory::Error, RpmsRpc::Conformance::BuildSurface::Error => e
      raise Refused, e.message
    end

    # The build a surface document came from: the rpcs.json header, and the file itself.
    def build_provenance(read)
      d = read[:doc]
      {
        "tag" => d["tag"], "rpms_version" => d["rpms_version"], "engine" => d["engine"], "rpms_ops_commit" => d["commit"],
        "source" => { "file" => File.basename(read[:path]), "sha256" => read[:sha256], "schema" => d["schema"] },
        # The raw files openrpms projected it from, as its header names them.
        "inputs" => d["inputs"].map { |file, sha| { "file" => "#{d['tag']}-#{file}", "sha256" => sha } }
      }
    end
  end
end
