# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"

# For live specs that prove an RPC the gem does not wrap: the reply's rows, a
# row's ^-pieces, and the DDR reads that check a reply against the file it
# reads. The call goes through the run's client, so the call log records it
# (call_log.rb) like any other.
module WireReads
  CPRS_CHART = "OR CPRS GUI CHART"

  private

  # The reply's rows, as strings.
  def rows(rpc, *params) = Array(client.call_rpc(rpc, *params)).map(&:to_s)

  # The rows of an RPC registered in OR CPRS GUI CHART, sent under that option,
  # as the gem's mappings send it (ADR 0011, point 5).
  def chart_rows(rpc, *params) = client.with_context(CPRS_CHART) { rows(rpc, *params) }

  # The one row of a single-value reply.
  def value(rpc, *params)
    got = rows(rpc, *params)
    assert_equal 1, got.size, "#{rpc} answers one row: #{got.inspect}"
    got.first
  end

  def pieces(row) = row.to_s.split("^", -1)

  # Today on the server, as FileMan's YYYMMDD.
  def fm_today = value("ORWU DT", "T").to_i

  # Every entry of a file (or subfile), internal values: [{ ien:, pieces: }].
  def listed(file, fields, iens: nil, xref: "#")
    RpmsRpc::DdrFileman.list_all(file: file, fields: fields, iens: iens, xref: xref)
  end

  # One entry's fields, { field => { internal:, external: } }.
  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end

  # An RPC of OR CPRS GUI CHART, refused to a role whose row does not hold it.
  def assert_chart_refused(rpc, *params)
    error = assert_raises(RpmsRpc::Client::RpcRefusedError, "#{role} does not hold #{CPRS_CHART}, and #{rpc} answered") do
      chart_rows(rpc, *params)
    end
    assert_match(/Access denied for remote procedure/, error.message)
  end
end
