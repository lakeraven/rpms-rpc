# frozen_string_literal: true

# Changelog fragments: one file per PR in changelog.d/, assembled under `## [Unreleased]` in
# CHANGELOG.md at release. Each PR adds a uniquely named file, so two PRs never edit the same lines.
#
# A fragment is `<id>.<type>.md`: <id> is the issue or PR number, <type> one of TYPES. The first
# line is the heading (the text after `### <Type> — `); the rest of the file is the body, verbatim.
module Fragments
  class Error < StandardError; end

  TYPES = %w[added changed deprecated removed fixed security].freeze
  NAME = /\A(\d+)\.([^.]+)\.md\z/
  UNRELEASED = /^## \[Unreleased\][ \t]*\r?$/
  IGNORED = %w[README.md .keep .gitkeep .DS_Store].freeze

  Fragment = Struct.new(:id, :type, :heading, :body, :path, keyword_init: true)
  Assembly = Struct.new(:text, :files, keyword_init: true)

  module_function

  # Every fragment in dir, validated, in render order (type, then numeric id).
  def load(dir)
    names = Dir.children(dir).reject { |n| IGNORED.include?(n) }
    list = names.map { |n| parse(File.join(dir, n)) }
    list.group_by { |f| [ f.type, f.id ] }.each_value do |same|
      next if same.size == 1

      raise Error, "#{same.map { |f| File.basename(f.path) }.sort.join(' and ')}: both are #{same.first.type} fragments for id #{same.first.id}"
    end
    list.sort_by { |f| [ TYPES.index(f.type), f.id ] }
  end

  def parse(path)
    name = File.basename(path)
    raise Error, "#{name}: not a fragment file (directories are not read)" if File.directory?(path)

    match = NAME.match(name) or raise Error, "#{name}: not named <id>.<type>.md with a numeric id"
    type = match[2]
    raise Error, "#{name}: unknown type #{type.inspect} (expected one of #{TYPES.join(', ')})" unless TYPES.include?(type)

    text = File.read(path, encoding: "UTF-8")
    raise Error, "#{name}: file is empty" if text.strip.empty?

    heading, body = text.split("\n", 2)
    heading = heading.to_s.chomp("\r").strip
    raise Error, "#{name}: first line must be the heading text, not blank" if heading.empty?

    Fragment.new(id: match[1].to_i, type: type, heading: heading, body: body.to_s.sub(/\A(?:[ \t]*\r?\n)+/, "").rstrip, path: path)
  end

  def render(fragments)
    ordered = fragments.sort_by { |f| [ TYPES.index(f.type), f.id ] }
    ordered.map do |f|
      head = "### #{f.type.capitalize} — #{f.heading}\n"
      f.body.empty? ? head : "#{head}\n#{f.body}\n"
    end.join("\n")
  end

  # Inserts the rendered fragments immediately under `## [Unreleased]`, ahead of existing sections.
  def assemble(changelog_path:, dir:)
    text = File.read(changelog_path, encoding: "UTF-8")
    raise Error, "#{changelog_path}: no `## [Unreleased]` heading to insert under" unless text.match?(UNRELEASED)

    fragments = self.load(dir)
    return Assembly.new(text: text, files: []) if fragments.empty?

    out = text.sub(UNRELEASED) { |heading| "#{heading}\n\n#{render(fragments).chomp}" }
    Assembly.new(text: out, files: fragments.map(&:path))
  end
end
