# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/api/session"
require_relative "../captured_replies"

# CIAVCXUS VIMINFO (VIMINFO^CIAVCXUS) answers one row the routine documents
# itself (CIAVCXUS.m:20-21) and builds at CIAVCXUS.m:25-31:
#   DUZ ^ NAME ^ PTMOUT;STMOUT;CNTDN ^ COMPOSE MODE ^ DESIGN MODE
# It carries no site at all. The mapping read piece 1 (the DUZ) as :site_ien
# and the user's name as :site_name (#221). The reply is the one a fresh
# container of the pinned build sent for DUZ 206
# (test/fixtures/captured_replies/ciavcxus-viminfo.yml), replayed through CiaClient.
class SessionVimInfoWireTest < Minitest::Test
  def setup
    RpmsRpc.reset!
    reply = CapturedReplies.raw("ciavcxus-viminfo", "profile_md")
    RpmsRpc.configure { |cfg| cfg.client = CapturedReplies::ReplayCiaClient.new("CIAVCXUS VIMINFO" => [ reply ]) }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_viminfo_maps_the_routine_layout
    info = RpmsRpc::DataMapper.session_vim_info.fetch_one("206")

    assert_equal 206, info[:duz]
    assert_equal "PROFILE,MD", info[:user_name]
    # Piece 3 is ";"-delimited inside the caret piece (CIAVCXUS.m:27-30).
    assert_equal "1800;1800;60", info[:timeouts]
    assert_equal false, info[:compose_mode]
    assert_equal false, info[:design_mode]
  end

  def test_viminfo_carries_no_site
    info = RpmsRpc::DataMapper.session_vim_info.fetch_one("206")

    refute info.key?(:site_ien)
    refute info.key?(:site_name)
  end
end
