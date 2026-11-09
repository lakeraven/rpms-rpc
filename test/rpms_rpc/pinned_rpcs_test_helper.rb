# frozen_string_literal: true

require "fileutils"
require "json"
require "yaml"
require "rpms_rpc/conformance/inventory_lock"

# Real inputs for the tests of the RPC-surface reader and its callers (rpms-rpc#406): records taken
# from the pinned build's own <tag>-rpcs.json, as rpms-ops published it, written into a temp dir with
# at most the one change a test is about. No record here is hand-written.
module PinnedRpcsTestHelper
  ROOT = File.expand_path("../..", __dir__)
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(ROOT, "data/fingerprints", Lock::DEFAULT_PATH))
  TAG = LOCK.entries.keys.first
  INVENTORY_DIR = File.join(ROOT, "data/inventories", TAG)
  PATH = File.join(INVENTORY_DIR, "#{TAG}-#{Lock::RPCS_SUFFIX}")

  module_function

  # The pinned document, parsed once; callers get copies.
  def pinned_doc = @pinned_doc ||= JSON.parse(File.read(PATH, encoding: "UTF-8")).freeze

  def copy(value) = Marshal.load(Marshal.dump(value))

  # The pinned record for NAME (a copy), with REACH merged into its reach object when given.
  def record(name, reach: nil)
    @by_name ||= pinned_doc["rpcs"].to_h { |r| [ r["name"], r ] }
    rec = @by_name[name] or raise "#{name} is not registered on #{TAG}"
    rec = copy(rec)
    rec["reach"].merge!(reach) if reach
    rec
  end

  def records(*names) = names.map { |n| record(n) }

  # The first pinned record whose reach class is CLASS (a copy).
  def record_of_class(klass)
    rec = pinned_doc["rpcs"].find { |r| r.dig("reach", "class") == klass } or raise "#{TAG} has no #{klass} RPC"
    copy(rec)
  end

  # A document of RECORDS under the pinned header, retagged TAG. sort: false keeps the given order.
  def doc(records, tag: TAG, sort: true)
    records = records.sort_by { |r| r["name"].b } if sort
    copy(pinned_doc.except("rpcs")).merge("tag" => tag, "rpcs" => records)
  end

  # Write DOC (or RECORDS as a document) as DIR/<tag>/<tag>-rpcs.json; returns that dir.
  def write_inventory(root, tag, records = nil, document: nil, sort: true)
    dir = File.join(root, tag)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{tag}-#{Lock::RPCS_SUFFIX}"), JSON.generate(document || doc(records, tag: tag, sort: sort)))
    dir
  end

  # A copy of the whole pinned inventory dir under ROOT/<TAG>/; returns that dir.
  def copy_pinned_inventory(root)
    FileUtils.cp_r(INVENTORY_DIR, root)
    File.join(root, TAG)
  end
end
