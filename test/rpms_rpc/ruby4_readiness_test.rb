# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Ruby 4 readiness (#47): the breakages Ruby 4.0 and Minitest 6 are known to bring, each pinned so
# it cannot come back unnoticed. The suite runs on the one Ruby .ruby-version names (4.0).
class Ruby4ReadinessTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def ruby_sources
    files = Dir.chdir(ROOT) { Dir["{lib,test,tools,bin}/**/*.rb", "lib/tasks/*.rake", "Rakefile", "Gemfile", "*.gemspec"] }
    scripts = Dir.chdir(ROOT) { Dir["bin/*"].reject { |f| File.extname(f) != "" || File.directory?(f) } }
    scripts = scripts.select { |f| File.open(File.join(ROOT, f), &:gets).to_s.match?(/\A#!.*ruby/) }
    (files + scripts).sort
  end

  # Minitest 6 moved Minitest::Mock and Object#stub into a separate gem, and minitest 5's autorun
  # loads them implicitly, so a new .stub would work today and break on the upgrade.
  def test_no_test_uses_minitest_mock_or_stub
    pattern = /minitest\/mock|Minitest::Mock|\.stub\(/
    hits = Dir.chdir(ROOT) { Dir["test/**/*.rb"] }.reject { |f| f.end_with?("ruby4_readiness_test.rb") }.flat_map do |f|
      File.readlines(File.join(ROOT, f)).each_with_index.select { |l, _| l.match?(pattern) }.map { |_, i| "#{f}:#{i + 1}" }
    end
    assert_empty hits, "use dependency injection instead of minitest/mock (it is not in Minitest 6)"
  end

  # Ruby 3.4 and 4.0 turned default gems into bundled gems (bigdecimal, ostruct, mutex_m, drb,
  # observer, abbrev, getoptlong, logger, benchmark, irb ...). Under Bundler a bundled gem only loads
  # if something declares it. Ruby's own list (Gem::BUNDLED_GEMS::SINCE, which on 3.4 already names
  # the gems 4.0 unbundles) is the reference.
  def bundled_gems
    require "bundled_gems"
    Gem::BUNDLED_GEMS::SINCE.keys
  end

  def required_gems(files)
    files.flat_map { |f| File.read(File.join(ROOT, f)).scan(/^\s*require\s+["']([^"']+)["']/).flatten }
         .reject { |r| r.start_with?("rpms_rpc") }.map { |r| r.split("/").first }.uniq.sort
  end

  def gemspec = Gem::Specification.load(File.join(ROOT, "rpms-rpc.gemspec"))

  def test_every_bundled_gem_lib_requires_is_a_runtime_dependency
    lib = Dir.chdir(ROOT) { Dir["lib/**/*.rb"] }
    missing = required_gems(lib) & bundled_gems - gemspec.runtime_dependencies.map(&:name)
    assert_empty missing, "lib/ requires these bundled (non-default) gems without declaring them in the gemspec"
  end

  # bin/ scripts run from a checkout under Bundler, so the Gemfile may carry them instead.
  def test_every_bundled_gem_bin_requires_is_in_the_bundle
    declared = gemspec.dependencies.map(&:name) + File.read(File.join(ROOT, "Gemfile")).scan(/^\s*gem\s+["']([^"']+)["']/).flatten
    bin = ruby_sources.select { |f| f.start_with?("bin/") }
    missing = required_gems(bin) & bundled_gems - declared
    assert_empty missing, "bin/ requires these bundled (non-default) gems without a Gemfile or gemspec entry"
  end

  def test_ci_runs_the_suite_with_frozen_string_literals
    ci = YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"))
    run = ci.dig("jobs", "test", "steps").find { |s| s["run"].to_s.include?("rake test") }
    assert_includes run.dig("env", "RUBYOPT").to_s, "--enable-frozen-string-literal"
  end

  # CI runs one Ruby: every setup-ruby step names the minor .ruby-version names (setup-ruby then
  # takes the newest patch the runner has; .ruby-version pins the patch rbenv installs), and that
  # Ruby satisfies the gemspec floor.
  def test_ci_runs_the_ruby_version_files_minor_and_it_meets_the_gemspec_floor
    ruby = Gem::Version.new(File.read(File.join(ROOT, ".ruby-version")).strip)
    minor = ruby.segments.first(2).join(".")
    named = Dir[File.join(ROOT, ".github/workflows/*.yml")].flat_map do |wf|
      YAML.safe_load_file(wf)["jobs"].flat_map do |name, job|
        Array(job["steps"]).select { |s| s["uses"].to_s.start_with?("ruby/setup-ruby") }
                           .map { |s| [ "#{File.basename(wf)}:#{name}", s.dig("with", "ruby-version").to_s ] }
      end
    end
    refute_empty named
    wrong = named.reject { |_, version| version == minor }
    assert_empty wrong, "these setup-ruby steps do not name #{minor} (.ruby-version is #{ruby})"
    assert gemspec.required_ruby_version.satisfied_by?(ruby),
      ".ruby-version #{ruby} does not satisfy the gemspec floor #{gemspec.required_ruby_version}"
  end

  # With the magic comment on every file, --enable-frozen-string-literal (CI runs the suite with it)
  # changes nothing, and a literal mutated in place fails today rather than on a default flip.
  def test_every_ruby_source_has_the_frozen_string_literal_comment
    missing = ruby_sources.reject do |f|
      File.foreach(File.join(ROOT, f)).first(3).any? { |l| l.match?(/\A# frozen_string_literal: true\s*\z/) }
    end
    assert_empty missing
  end
end
