# frozen_string_literal: true

require "cgi"
require "json"
require "open3"

# The conformance matrix (rpms-rpc#724): which rpms-rpc behaviour held on which openrpms release, per RPC and per
# engine. It is a view, not a data file: every openrpms release already carries <tag>-rpms-rpc-live.json, the per-RPC
# record of what rpms-rpc proved there, and this reads the last N of them and renders one page. Nothing is committed.
#
#   rake openrpms:matrix [N=12] [OUT=tmp/openrpms/matrix.html]
#
# A record is rpms-rpc-live.v2 (a verdict per registered RPC: pass, fail, known-failure with its issue, not-run,
# excluded) or, for releases published before the train, v1 (an outcome per RPC the live suite sent: ok or error,
# read as pass or fail). A row is an RPC some release exercised; a cell is its verdict there, blank where that
# release's record does not cover it. Which pin lives where: openrpms docs/PINS.md.
module OpenrpmsMatrix
  OPENRPMS = "lakeraven/openrpms"
  TAG = /\Abcer-\d+\.\d+-(?<date>\d{8})-[0-9a-f]{7,40}-(?<engine>ydb|iris)\z/
  EXERCISED = %w[pass fail known-failure].freeze

  Column = Struct.new(:tag, :engine, :record, keyword_init: true)

  module_function

  def record_asset(tag) = "#{tag}-rpms-rpc-live.json"

  # The newest N published releases that carry a record, newest first, from a GitHub releases list.
  def releases(list, n)
    Array(list).select do |r|
      r.is_a?(Hash) && r["draft"] == false && r["prerelease"] == false && TAG.match?(r["tag_name"].to_s) &&
        Array(r["assets"]).any? { |a| a["name"] == record_asset(r["tag_name"]) }
    end.sort_by { |r| r["published_at"].to_s }.reverse.first(n)
  end

  # { rpc => { "verdict" =>, "issue" => } } for one record, v2 or v1.
  def cells(record)
    rpcs = record.is_a?(Hash) && record["rpcs"].is_a?(Hash) ? record["rpcs"] : {}
    rpcs.to_h do |name, e|
      verdict = if record["record"] == "rpms-rpc-live.v2" then e["verdict"].to_s
      else e["outcome"] == "ok" ? "pass" : "fail"
      end
      [ name, { "verdict" => verdict, "issue" => e["issue"] }.compact ]
    end
  end

  # { columns: [Column], rows: { rpc => [cell or nil per column] } }: the RPCs some column exercised, sorted.
  def matrix(columns)
    per = columns.map { |c| cells(c.record) }
    names = per.flat_map { |p| p.select { |_, v| EXERCISED.include?(v["verdict"]) }.keys }.uniq.sort
    { columns: columns, rows: names.to_h { |n| [ n, per.map { |p| p[n] } ] } }
  end

  def schema(record) = record["record"] == "rpms-rpc-live.v2" ? "v2" : "v1"

  def html(m)
    h = ->(s) { CGI.escapeHTML(s.to_s) }
    head = m[:columns].map do |c|
      "<th\n scope=\"col\"\n title=\"#{h.(c.tag)} (record #{schema(c.record)})\">#{h.(c.tag.sub(/\Abcer-[\d.]+-/, ''))}</th>"
    end
    body = m[:rows].map do |name, row|
      tds = row.map do |cell|
        next "<td></td>" unless cell

        v = cell["verdict"]
        text = cell["issue"] ? "<a\n href=\"#{h.(cell['issue'])}\">#{h.(v)}</a>" : h.(v)
        "<td\n class=\"#{h.(v)}\">#{text}</td>"
      end
      "<tr><th\n scope=\"row\">#{h.(name)}</th>#{tds.join}</tr>"
    end
    <<~HTML
      <!doctype html>
      <html
       lang="en">
      <head>
      <meta
       charset="utf-8">
      <meta
       name="viewport"
       content="width=device-width, initial-scale=1">
      <title>rpms-rpc conformance matrix</title>
      <style>
      :root { --bg: #fff; --fg: #1a1a1a; --line: #ddd; --pass: #d8f0dc; --fail: #f6d4d4; --known: #f6ecc8; --other: #eee; }
      @media (prefers-color-scheme: dark) { :root { --bg: #161616; --fg: #e8e8e8; --line: #333; --pass: #1e3b25; --fail: #4a2020; --known: #463c17; --other: #2a2a2a; } }
      body { background: var(--bg); color: var(--fg); font: 13px/1.4 system-ui, sans-serif; margin: 16px; }
      .wrap { overflow-x: auto; }
      table { border-collapse: collapse; }
      th, td { border: 1px solid var(--line); padding: 2px 6px; white-space: nowrap; }
      thead th { position: sticky; top: 0; background: var(--bg); }
      td.pass { background: var(--pass); } td.fail { background: var(--fail); } td.known-failure { background: var(--known); }
      td.not-run, td.excluded { background: var(--other); }
      a { color: inherit; }
      </style>
      </head>
      <body>
      <h1>rpms-rpc conformance matrix</h1>
      <p>
      Each column is an openrpms release, newest first, read from its <code>&lt;tag&gt;-rpms-rpc-live.json</code>.
      Each row is an RPC some release exercised; a blank cell means that release's record does not cover it.
      v1 records (before the release train) give ok or error, shown as pass or fail.
      </p>
      <div
       class="wrap">
      <table>
      <thead><tr><th
       scope="col">RPC</th>#{head.join}</tr></thead>
      <tbody>
      #{body.join("\n")}
      </tbody>
      </table>
      </div>
      </body>
      </html>
    HTML
  end

  # The last N releases' columns, read from openrpms with gh (GH_TOKEN, or `gh auth login`).
  def fetch(n)
    out, err, st = Open3.capture3("gh", "api", "--paginate", "--slurp", "repos/#{OPENRPMS}/releases")
    raise "cannot list #{OPENRPMS} releases (#{err.to_s.lines.first.to_s.strip}); a token that can read it is needed" unless st.success?

    releases(JSON.parse(out).flatten(1), n).map do |r|
      tag = r["tag_name"]
      asset = r["assets"].find { |a| a["name"] == record_asset(tag) }
      body, err, st = Open3.capture3("gh", "api", "-H", "Accept: application/octet-stream", "repos/#{OPENRPMS}/releases/assets/#{asset['id']}")
      raise "cannot download #{record_asset(tag)} (#{err.to_s.lines.first.to_s.strip})" unless st.success?

      Column.new(tag: tag, engine: TAG.match(tag)[:engine], record: JSON.parse(body))
    end
  end
end
