# frozen_string_literal: true

require "fileutils"

# The rpc:coverage report drawn in SimpleCov's HTML interface (`rake rpc:coverage_html`).
#
# SimpleCov renders files made of lines, each hit, missed or never relevant. Here:
#   file  one #9.4 PACKAGE: the RPCs whose NAME begins with that package's namespace PREFIX
#         (longest prefix wins). A name no prefix claims is grouped by its own namespace and
#         labelled "not a #9.4 package" (AKFR, BMQ, the PCMM SC* RPCs, GMV, DDR on the 0913
#         registry): registered RPCs from namespaces the release has no PACKAGE entry for.
#   line  one registered RPC, its text "NAME  status  detail" from the rpc:coverage row
#   hit       covered            a live run against the backend got an answer (not a broker error)
#   missed    live_error, declared_untested, not_declared
#   never     excluded:<reason>  outside the denominator, with the reason on the line
# So SimpleCov's percentage for a package is covered / (registered - excluded) for that package, the
# same arithmetic as the rpc:coverage headline, and its total is the headline number.
#
# The "source files" are generated text under <out>/src; they exist only so SimpleCov has lines to
# show. Nothing here reads Ruby coverage.
module RpcCoverage
  module Html
    NO_PACKAGE = "not a #9.4 package"

    module_function

    # [[prefix, name], ...] from the pinned #9.4 list (PREFIX^NAME^VERSION), longest prefix first.
    def load_packages(path)
      raise Error, "package list not found: #{path}" unless File.exist?(path)

      rows = File.readlines(path, chomp: true).reject { |l| l.strip.empty? || l.start_with?("#") }
      pkgs = rows.map { |l| l.split("^", 3).first(2) }.reject { |p, _| p.to_s.empty? }
      raise Error, "package list #{path} has no packages" if pkgs.empty?

      pkgs.sort_by { |p, n| [ -p.length, p, n.to_s ] }
    end

    def package_for(name, packages)
      packages.find { |prefix, _| name.start_with?(prefix) } || [ namespace(name), NO_PACKAGE ]
    end

    # The namespace of a name no package claims: the leading letters of its first word, at most 4
    # (IHS and VA namespaces are 2-4 characters): "AKFRACH ..." -> AKFR, "GMV ..." -> GMV.
    def namespace(name)
      name[/\A[A-Z%]+/].to_s[0, 4].then { |ns| ns.empty? ? name.split(" ", 2).first : ns }
    end

    # SimpleCov line value for one rpc:coverage row.
    def hits(status)
      return nil if status.start_with?("excluded:")

      status == "covered" ? 1 : 0
    end

    def line_text(row)
      [ row[:name].ljust(32), row[:status].ljust(22), row[:detail].to_s ].join(" ").rstrip
    end

    def file_slug(prefix, name)
      "#{prefix} #{name}".gsub(/[^A-Za-z0-9%]+/, "-").gsub(/\A-|-\z/, "")
    end

    # { "<src>/<slug>.rpc" => { "lines" => [...] } }, and each file written with its lines.
    def write_sources(report, packages, src_dir)
      FileUtils.rm_rf(src_dir)
      FileUtils.mkdir_p(src_dir)
      groups = report.rows.group_by { |r| package_for(r[:name], packages) }
      groups.sort_by { |(prefix, _), _| prefix }.to_h do |(prefix, name), rows|
        path = File.join(src_dir, "#{file_slug(prefix, name)}.rpc")
        File.write(path, rows.map { |r| line_text(r) }.join("\n") + "\n")
        [ path, { "lines" => rows.map { |r| hits(r[:status]) } } ]
      end
    end

    # Renders <out>/index.html with simplecov-html. Returns the index path.
    def render(report, packages, out_dir)
      require "simplecov"
      require "simplecov-html"

      out_dir = File.expand_path(out_dir)
      src_dir = File.join(out_dir, "src")
      coverage = write_sources(report, packages, src_dir)
      SimpleCov.root(src_dir)
      SimpleCov.coverage_dir(File.join(out_dir, "html"))
      SimpleCov.project_name("RPC coverage: #{report.backend} on #{report.registry.tag}")
      result = SimpleCov::Result.new(coverage, command_name: "rpc:coverage #{report.backend}")
      SimpleCov::Formatter::HTMLFormatter.new.format(result)
      File.join(SimpleCov.coverage_path, "index.html")
    end
  end
end
