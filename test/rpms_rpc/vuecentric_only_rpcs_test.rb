# frozen_string_literal: true

require "minitest/autorun"
require "json"

# ADR 0011: every RPC the gem sends that the build registers in CIAV
# VUECENTRIC and no other broker option is listed in the ADR's table, with
# why it is kept (rpms-rpc#528). The set is computed: lib/rpms_rpc/required_rpcs.json
# joined with the broker-option inventory of the build it names
# (data/inventories/<build>/<build>-contexts_19_05.txt).
class VuecentricOnlyRpcsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  REQUIRED = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")
  ADR = File.join(ROOT, "docs/adr/0011-vuecentric-only-rpcs-the-gem-keeps.md")
  VUECENTRIC = "CIAV VUECENTRIC"

  def required
    @required ||= JSON.parse(File.read(REQUIRED))
  end

  # RPC name => the broker options the build lists it in.
  def options_by_rpc
    build = required.fetch("build")
    path = File.join(ROOT, "data/inventories", build, "#{build}-contexts_19_05.txt")
    assert File.file?(path), "no broker-option inventory for #{build} at #{path}"
    File.foreach(path).drop(1).each_with_object(Hash.new { |h, k| h[k] = [] }) do |line, out|
      option, _type, _lock, rpc = line.chomp.split("\t")
      out[rpc] << option unless rpc.to_s.empty?
    end
  end

  # RPC name => the modules required_rpcs.json says send it.
  def sent_by
    required.fetch("modules").each_with_object(Hash.new { |h, k| h[k] = [] }) do |(mod, rpcs), out|
      rpcs.each { |rpc| out[rpc] << mod }
    end
  end

  def vuecentric_only
    options = options_by_rpc
    sent_by.keys.select { |rpc| options[rpc].uniq == [ VUECENTRIC ] }.sort
  end

  # The ADR table's rows: RPC => the "Used by" cell's module names.
  def adr_rows
    File.readlines(ADR).filter_map do |line|
      cells = line.split("|").map(&:strip)
      next unless cells[1].to_s.match?(/\A`[^`]+`\z/)

      [ cells[1].delete("`"), cells[2].to_s.scan(/`([^`]+)`/).flatten ]
    end.to_h
  end

  def test_every_vuecentric_only_rpc_the_gem_sends_is_in_the_adr
    missing = vuecentric_only - adr_rows.keys
    assert_empty missing, "VueCentric-only RPCs the gem sends with no row in #{File.basename(ADR)}: #{missing.join(', ')}"
  end

  def test_the_adr_lists_only_rpcs_that_are_still_vuecentric_only_and_sent
    stale = adr_rows.keys - vuecentric_only
    assert_empty stale, "#{File.basename(ADR)} lists RPCs that are no longer VueCentric-only or no longer sent: #{stale.join(', ')}"
  end

  def test_each_row_names_the_modules_that_send_it
    rows = adr_rows
    vuecentric_only.each do |rpc|
      assert_equal sent_by[rpc].sort, rows.fetch(rpc, []).sort, "#{rpc}: the Used by cell disagrees with required_rpcs.json"
    end
  end

  def test_the_adr_count_matches
    assert_match(/that is #{vuecentric_only.size} RPCs/, File.read(ADR), "the ADR's stated count is not #{vuecentric_only.size}")
  end
end
