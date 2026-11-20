# frozen_string_literal: true

# The conformance matrix (rpms-rpc#724): RPC by openrpms release by engine, from the last N releases'
# <tag>-rpms-rpc-live.json records. Renders one local page; commits nothing (tools/openrpms_matrix.rb).
namespace :openrpms do
  desc "Render the conformance matrix from the last N openrpms releases' records (N=12, OUT=tmp/openrpms/matrix.html)"
  task :matrix do
    require "fileutils"
    root = File.expand_path("../..", __dir__)
    tool = File.join(root, "tools/openrpms_matrix.rb")
    abort "openrpms:matrix: needs a source checkout (#{tool} is not in the gem)" unless File.file?(tool)
    require tool

    n = Integer(ENV.fetch("N", "12"), exception: false)
    abort "openrpms:matrix: N must be a positive integer, not #{ENV['N'].inspect}" unless n&.positive?
    out = File.expand_path(ENV["OUT"] || "tmp/openrpms/matrix.html", root)
    begin
      columns = OpenrpmsMatrix.fetch(n)
    rescue RuntimeError, JSON::ParserError => e
      abort "openrpms:matrix: #{e.message}"
    end
    abort "openrpms:matrix: no published openrpms release carries a #{OpenrpmsMatrix.record_asset('<tag>')}" if columns.empty?

    m = OpenrpmsMatrix.matrix(columns)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, OpenrpmsMatrix.html(m))
    abort "openrpms:matrix: #{out} is empty" unless File.size?(out)

    puts "EXPLICIT SUCCESS: openrpms:matrix wrote #{out.delete_prefix("#{root}/")}: #{m[:rows].size} RPCs over " \
         "#{columns.size} releases (#{columns.map(&:engine).tally.map { |e, c| "#{c} #{e}" }.join(', ')})"
  end
end
