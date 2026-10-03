# frozen_string_literal: true

require "minitest/autorun"
require "yaml"

# Ruby 4 readiness (#47): the breakages Ruby 4.0 and Minitest 6 are known to bring, each pinned so
# it cannot come back unnoticed. The suite itself runs on 3.4 and 4.0 in CI.
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
  # observer, abbrev, getoptlong, logger, benchmark ...). Under Bundler a bundled gem only loads if
  # something declares it, so every non-default gem lib/ requires must be a runtime dependency.
  def test_every_non_default_gem_lib_requires_is_a_runtime_dependency
    spec = Gem::Specification.load(File.join(ROOT, "rpms-rpc.gemspec"))
    declared = spec.runtime_dependencies.map(&:name)
    required = Dir[File.join(ROOT, "lib/**/*.rb")].flat_map do |f|
      File.read(f).scan(/^\s*require\s+["']([^"']+)["']/).flatten
    end
    gems = required.reject { |r| r.start_with?("rpms_rpc") }.map { |r| r.split("/").first }.uniq.sort
    missing = gems.select do |name|
      found = Gem::Specification.find_all_by_name(name)
      found.any? && found.none?(&:default_gem?) && !declared.include?(name)
    end
    assert_empty missing, "lib/ requires these non-default gems without declaring them in the gemspec"
  end

  def test_ci_runs_the_suite_on_ruby_3_4_and_4_0_with_frozen_string_literals
    ci = YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml"))
    rubies = ci.dig("jobs", "test", "strategy", "matrix", "ruby")
    assert_includes rubies, "3.4"
    assert_includes rubies, "4.0"
    run = ci.dig("jobs", "test", "steps").find { |s| s["run"].to_s.include?("rake test") }
    assert_includes run.dig("env", "RUBYOPT").to_s, "--enable-frozen-string-literal"
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
