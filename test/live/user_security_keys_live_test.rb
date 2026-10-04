# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/security_keys"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/ddr_fileman"

# Authentication.user_security_keys(duz) lists the keys a user holds, read
# with DDR LISTER over the KEYS multiple of NEW PERSON (#200 field 51, subfile
# 200.051, whose .01 KEY points to SECURITY KEY #19.1). DDR LISTER is in CIAV
# VUECENTRIC, the option sign-on binds, so the spec binds it explicitly; it
# reads only.
#
# What a persona holds is the build's seed, not the gem's contract, so the
# spec checks the list against the server's own per-key answer (ORWU NPHASKEY,
# through has_security_key?): every listed key is held, and every key
# SecurityKeys names (and a few common ones) that the server says is held is
# listed. That makes an empty list (the provider persona holds no keys on the
# demo build) a checked answer, not a refusal read as "none".
class UserSecurityKeysLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  # The keys SecurityKeys names, plus the common clinical and programmer keys
  # (all SECURITY KEY #19.1 entries on the build).
  PROBED = (RpmsRpc::SecurityKeys::REGISTRY.values + %w[PROVIDER ORES ORELSE XUPROG XUPROGMODE XUMGR]).freeze

  def test_lists_the_keys_the_server_says_the_user_holds
    duz = client.duz
    refute_nil duz, "sign-on as #{persona} set no DUZ"

    raw = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: "200.051", iens: ",#{duz},", fields: "@;.01")
    end
    refute_nil raw, "DDR LISTER on 200.051 gave no reply for #{persona}"
    refute raw[:error], "DDR LISTER on 200.051 answered with errors for #{persona}: #{raw.inspect}"

    keys = client.with_context(CONTEXT) { RpmsRpc::Authentication.user_security_keys(duz) }
    assert_kind_of Array, keys
    keys.each { |k| assert(k.is_a?(String) && !k.strip.empty?, "key #{k.inspect} is not a name") }
    assert_equal keys.uniq, keys, "a key is listed twice"
    assert_equal raw[:entries].size, keys.size, "every 200.051 entry should yield one key name"

    client.with_context(CONTEXT) do
      keys.each do |k|
        assert RpmsRpc::Authentication.has_security_key?(duz, k),
               "#{k} is listed for #{persona}, but ORWU NPHASKEY says it is not held"
      end
      PROBED.each do |name|
        next unless RpmsRpc::Authentication.has_security_key?(duz, name)

        assert_includes keys, name, "ORWU NPHASKEY says #{persona} holds #{name}, but it is not listed"
      end
    end

    puts "\n#{persona} holds #{keys.size} key(s)#{": #{keys.first(5).join(', ')}..." unless keys.empty?}"
  end

  def test_an_invalid_duz_lists_nothing
    [ nil, "", "0", "-1", "abc" ].each do |bad|
      assert_equal [], RpmsRpc::Authentication.user_security_keys(bad), "user_security_keys(#{bad.inspect})"
    end
  end
end
