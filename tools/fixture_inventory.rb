# frozen_string_literal: true

# Cut the small committed fixture inventory the offline unit tests read (rpms-rpc#724) from a real
# openrpms release inventory. Every record is copied verbatim from the release; only the set is cut:
#
#   rpcs.json            the records named in NAMES (one per line), in the release's order
#   contexts_19_05.txt   the header and every row whose RPC is in that set
#   packages_9_4.txt     unchanged
#   PROVENANCE.json      unchanged (the build record)
#   INVENTORY-PROVENANCE the RPC counts and reach classes recounted for the cut set
#   INVENTORY.sha256     the contexts and provenance lines resealed; the raw dumps' lines unchanged
#
# so ReleaseInventory.verify_dir accepts the result as it would the release.
#
#   ruby tools/fixture_inventory.rb <release dir> <tag> <out root> <names file>
require "digest"
require "fileutils"
require "json"

src, tag, out_root, names_file = ARGV
abort "usage: ruby tools/fixture_inventory.rb <release dir> <tag> <out root> <names file>" unless names_file

names = File.readlines(names_file, chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
wanted = names.to_h { |n| [ n, true ] }
asset = ->(dir, suffix) { File.join(dir, "#{tag}-#{suffix}") }
out = File.join(out_root, tag)
FileUtils.mkdir_p(out)

doc = JSON.parse(File.read(asset.(src, "rpcs.json"), encoding: "UTF-8"))
doc["rpcs"] = doc["rpcs"].select { |r| wanted[r["name"]] }
missing = names - doc["rpcs"].map { |r| r["name"] }
abort "not registered on #{tag}: #{missing.join(', ')}" unless missing.empty?

contexts = File.readlines(asset.(src, "contexts_19_05.txt"))
File.write(asset.(out, "contexts_19_05.txt"), contexts.first + contexts.drop(1).select { |l| wanted[l.split("\t")[3]] }.join)
%w[packages_9_4.txt PROVENANCE.json].each { |s| FileUtils.cp(asset.(src, s), asset.(out, s)) }

prov = JSON.parse(File.read(asset.(src, "INVENTORY-PROVENANCE.json")))
n = doc["rpcs"].size
prov["dumps"]["rpcs"]["records"] = n
prov["rpc_reach"]["records"] = n
prov["rpc_reach"]["classes"] = doc["rpcs"].map { |r| r.dig("reach", "class") }.tally.sort.to_h
prov["rpc_signatures"]["rpcs"] = n
File.write(asset.(out, "INVENTORY-PROVENANCE.json"), "#{JSON.pretty_generate(prov)}\n")

sha = ->(suffix) { Digest::SHA256.file(asset.(out, suffix)).hexdigest }
doc["inputs"]["INVENTORY-PROVENANCE.json"] = sha.("INVENTORY-PROVENANCE.json")
File.write(asset.(out, "rpcs.json"), "#{JSON.pretty_generate(doc)}\n")

resealed = %w[contexts_19_05.txt INVENTORY-PROVENANCE.json].to_h { |s| [ "#{tag}-#{s}", sha.(s) ] }
sidecar = File.readlines(asset.(src, "INVENTORY.sha256"), chomp: true).map do |line|
  _, name = line.split(/\s+\*?/, 2)
  resealed.key?(name) ? "#{resealed[name]}  #{name}" : line
end
File.write(asset.(out, "INVENTORY.sha256"), "#{sidecar.join("\n")}\n")
puts "wrote #{out}: #{n} RPCs, #{File.readlines(asset.(out, 'contexts_19_05.txt')).size - 1} context rows"
