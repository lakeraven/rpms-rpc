# frozen_string_literal: true

# The openrpms release the gem tests against (rpms-rpc#724 step 1): the latest published YottaDB
# release, looked up when the tests run, never a commit or tag pinned in this repo.
#
#   rake openrpms:fetch      resolve the release (OPENRPMS_RELEASE=<tag> names one; default the latest
#                            bcer-*-ydb release that carries its inventory), download its RPC surface
#                            into tmp/openrpms/<tag>/ (OPENRPMS_INVENTORIES= moves the cache), verify
#                            every byte, and record it in tmp/openrpms/current.json
#   rake openrpms:current    print the release current.json records, verified, without the network
#
# The name gate, the callable gate and Features read that recorded release. Reading
# lakeraven/openrpms needs a token that can (gh auth, or GH_TOKEN in CI).
namespace :openrpms do
  desc "Fetch and verify the openrpms release to test against (OPENRPMS_RELEASE=<tag>, default the latest -ydb)"
  task :fetch do
    require "rpms_rpc"
    require "rpms_rpc/conformance/release_inventory"

    release = RpmsRpc::Conformance::ReleaseInventory
    root = release.cache_root
    begin
      inv = release.resolve!(root: root)
    rescue release::Error => e
      abort "openrpms:fetch: #{e.message}"
    end
    record = release.current_record(root: root)
    puts "openrpms:fetch: testing against #{inv.tag} (chosen by #{record['chosen_by']}; " \
         "#{inv.surface.rpcs.size} RPCs, image #{inv.image_ref})"
    puts "  verified inventory: #{inv.dir}"
    puts "  recorded in:        #{File.join(root, release::CURRENT_FILE)}"
    if (out = ENV["GITHUB_OUTPUT"].to_s) != ""
      File.open(out, "a") do |f|
        f.puts "tag=#{inv.tag}"
        f.puts "image=#{inv.image_ref}"
        f.puts "current=#{File.join(root, release::CURRENT_FILE)}"
      end
    end
  end

  desc "Print the openrpms release this checkout tests against (tmp/openrpms/current.json), verified offline"
  task :current do
    require "rpms_rpc"
    require "rpms_rpc/conformance/release_inventory"

    release = RpmsRpc::Conformance::ReleaseInventory
    begin
      inv = release.current
    rescue release::Error => e
      abort "openrpms:current: #{e.message}"
    end
    puts "#{inv.tag} (#{inv.surface.rpcs.size} RPCs, image #{inv.image_ref}, #{inv.dir})"
  end
end
