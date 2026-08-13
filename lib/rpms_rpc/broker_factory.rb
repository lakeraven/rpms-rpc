# frozen_string_literal: true

module RpmsRpc
  # Broker selector — one EHR, both worlds. Returns the right client for the target broker so
  # application code stays broker-agnostic (all brokers share the ^XWB(8994) RPC registry; they
  # differ only in wire framing). rpms-rpc#173.
  #
  #   RpmsRpc.client_for(:xwb, host:, port:)  -> XwbClient        stock VistA: VA, WorldVistA, civilian
  #   RpmsRpc.client_for(:cia, host:, port:)  -> CiaClient  IHS RPMS: CIANBLIS / VueCentric
  #   RpmsRpc.client_for(:bmx, host:, port:)  -> BmxClient        IHS RPMS: BMXNet (.NET)
  #
  # With no kind, the default comes from ENV["VISTA_BROKER"] (default "xwb" — the portable
  # protocol every VistA speaks). Aliases: vista/va -> xwb, rpms/vuecentric -> cia, bmxnet -> bmx.
  module_function

  BROKER_ALIASES = {
    xwb: :xwb, vista: :xwb, va: :xwb,
    cia: :cia, rpms: :cia, vuecentric: :cia,
    bmx: :bmx, bmxnet: :bmx
  }.freeze

  def client_for(kind = nil, host: nil, port: nil, timeout: nil)
    requested = (kind || ENV.fetch("VISTA_BROKER", "xwb")).to_s.downcase.to_sym
    broker = BROKER_ALIASES[requested] or
      raise ArgumentError, "unknown broker #{requested.inspect}; expected one of #{BROKER_ALIASES.keys.inspect}"

    klass =
      case broker
      when :xwb then require "rpms_rpc/xwb_client"; XwbClient
      when :cia then require "rpms_rpc/cia_client"; CiaClient
      when :bmx then require "rpms_rpc/bmx_client"; BmxClient
      end
    klass.new(host: host, port: port, timeout: timeout)
  end
end
