# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/api/patient"
require "date"

# A refused context bind over BMX raises its own error, carrying the option,
# so a caller can tell "this user lacks the option" from any other RPC
# failure (rpms-rpc#756).
#
# CRCONTXT^XWBSEC answers XWB CREATE CONTEXT with 1, or with why not:
# "The context 'X' does not exist on server." for an unknown option, or
# $$CHK^XQCS's reason ("User ... does not have access to option X") for an
# option the user does not hold (XWBSEC.m). A holder of XUPROGMODE is let
# into any option that exists, so the refusal needs a user without it.
# A registration by that user is refused the same way: AG checks each field
# under AGGRPC, and the refused bind reaches the caller as a refusal, where it
# used to read as :validation_unavailable (#702 left this BMX path open).
# PROFILE,MA is that user on the build: a seeded persona whose secondary
# menus are BMXRPC, BSTSRPC, BSDXRPC and CIAV VUECENTRIC, and not AGGRPC
# (the release's personas.json). Its pair is a published demo pair.
#
#   BROKER_PROTOCOL=bmx BROKER_PORT=<the image's 9101> rake test:live
class BmxContextBindRefusedLiveTest < LiveSpec::Test
  runs_as "PMD123"
  broker :bmx
  connect_only!
  writes! # the registration spec is refused before AG files anything

  WITHOUT_AGGRPC = [ "PMA123", "PMA123!!" ].freeze
  HELD = "BMXRPC"
  NOT_HELD = "AGGRPC"
  UNKNOWN = "ZZ NO SUCH OPTION"

  def setup
    super
    client.authenticate(*WITHOUT_AGGRPC)
  rescue RpmsRpc::Client::AuthenticationError => e
    flunk "PROFILE,MA cannot sign on over BMX on this build (#{e.message}): has the persona seed changed?"
  end

  def test_an_option_the_user_does_not_hold_is_refused_by_name
    error = assert_raises(RpmsRpc::Client::ContextBindRefusedError) { client.create_context(NOT_HELD) }

    assert_equal NOT_HELD, error.option
    assert_kind_of RpmsRpc::Client::RpcRefusedError, error, "a host that rescues RpcRefusedError sees the refusal"
    assert_match(/does not have access to option #{NOT_HELD}/, error.message)
    assert_nil client.current_context, "CRCONTXT killed the broker context, so the client claims none"
  end

  def test_an_option_the_server_does_not_have_is_refused_by_name
    error = assert_raises(RpmsRpc::Client::ContextBindRefusedError) { client.create_context(UNKNOWN) }

    assert_equal UNKNOWN, error.option
    assert_match(/does not exist on server/, error.message)
  end

  def test_the_session_binds_an_option_it_holds_after_a_refusal
    assert_raises(RpmsRpc::Client::ContextBindRefusedError) { client.create_context(NOT_HELD) }

    assert client.create_context(HELD)
    assert_equal HELD, client.current_context
  end
def test_a_registration_by_a_user_without_aggrpc_is_refused_not_unavailable
  attrs = { name_last: "ZZBINDREFUSED", name_first: "DEMO", dob: Date.new(1901, 2, 3), sex: "F", no_ssn_reason: "N" }

  error = assert_raises(RpmsRpc::Client::RpcRefusedError) do
    RpmsRpc.with_client(client) { RpmsRpc::Registration.with_lookup_client(client) { RpmsRpc::Patient.register(attrs) } }
  end

  assert_kind_of RpmsRpc::Client::ContextBindRefusedError, error
  assert_equal NOT_HELD, error.option
end
end
