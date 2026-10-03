# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/session"

# CIAVCXUS VIMINFO (VIMINFO^CIAVCXUS) answers one row the routine documents
# itself (CIAVCXUS.m:20-21) and builds at CIAVCXUS.m:25-31:
#   DUZ ^ NAME ^ PTMOUT;STMOUT;CNTDN ^ COMPOSE MODE ^ DESIGN MODE
# It carries no site at all. The mapping read piece 1 (the DUZ) as :site_ien
# and the user's name as :site_name (#221).
class SessionVimInfoWireTest < Minitest::Test
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def setup
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new("301^PROVIDER,TEST^900;300;30^1^0") }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_viminfo_maps_the_routine_layout
    info = RpmsRpc::DataMapper.session_vim_info.fetch_one("301")

    assert_equal 301, info[:duz]
    assert_equal "PROVIDER,TEST", info[:user_name]
    # Piece 3 is ";"-delimited inside the caret piece (CIAVCXUS.m:27-30).
    assert_equal "900;300;30", info[:timeouts]
    assert_equal true, info[:compose_mode]
    assert_equal false, info[:design_mode]
  end

  def test_viminfo_carries_no_site
    info = RpmsRpc::DataMapper.session_vim_info.fetch_one("301")

    refute info.key?(:site_ien)
    refute info.key?(:site_name)
  end
end
