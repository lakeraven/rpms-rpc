# frozen_string_literal: true

require "json"
require "zlib"

# A real rpcs.v3 <tag>-rpcs.json (openrpms#1359), whole, gzipped with `gzip -9 -n`:
# test/fixtures/rpcs/bcer-9.0-20261124-60d39b6-ydb-rpcs.v3.json.gz (sha256 of the JSON c44f9b63...98c8).
#
# How it was made, with nothing hand-edited. openrpms branch local-integration-1124 (b58e435f), which moves
# release_rpcs_json.rb to rpcs.v3:
#   1. bin/rpc_reach_face.rb over test/fixtures/rpc_reachability/bcer-9.0-20261124-60d39b6-ydb.extract.gz, the
#      committed ZRPCRCH walk of that release's image, NEST lines included: a nine-field reach face, whose fields
#      1-7 are byte for byte the release's published <tag>-rpc_reach.txt.
#   2. bin/release_rpcs_json.rb over the release's published broker_8994.txt, rpc_signatures.txt,
#      packages_9_4.txt and INVENTORY-PROVENANCE.json, with that face as rpc_reach.txt (resealed).
# Over the published seven-field face the same writer gives the published <tag>-rpcs.json (rpcs.v2) byte for
# byte; and this file with reach.via dropped has that file's records exactly. Only the header's rpc_reach.txt
# sha256 differs, the nine-field face's against the published seven-field one's.
module RpcsV3Fixture
  TAG = "bcer-9.0-20261124-60d39b6-ydb"
  PATH = File.expand_path("../fixtures/rpcs/#{TAG}-rpcs.v3.json.gz", __dir__)
  # The published <tag>-rpc_reach.txt's sha256, as the published rpcs.v2 file's header names it.
  PUBLISHED_REACH_SHA256 = "96c709b06fa228fbdc1a693a1486268133c401b2da3cd832bb0b5e0d93461747"

  module_function

  def text = Zlib.gunzip(File.binread(PATH)).force_encoding(Encoding::UTF_8)
  def doc = JSON.parse(text)

  # The release's published rpcs.v2 document: this one with reach.via dropped, under its own header.
  def as_v2
    d = doc
    d["schema"] = "rpcs.v2"
    d["inputs"]["rpc_reach.txt"] = PUBLISHED_REACH_SHA256
    d["rpcs"].each { |r| r["reach"].delete("via") }
    d
  end

  # DIR/<TAG>-rpcs.json holding DOCUMENT (the fixture itself when nil); returns DIR.
  def write(dir, document = nil)
    File.write(File.join(dir, "#{TAG}-rpcs.json"), document ? JSON.generate(document) : text)
    dir
  end
end
