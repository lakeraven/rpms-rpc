# frozen_string_literal: true

require "json"
require "open3"

# rpms-rpc tags itself from published openrpms releases (the release train, rpms-rpc#724).
#
# An openrpms release gate runs rpms-rpc `main` as it stands at the cut and attaches two records to the release:
#
#   <tag>-harness.json         which rpms-rpc commit judged the release (harness.rpms_rpc_commit), and the tag that
#                              commit takes (harness.rpms_rpc_tag, the release's own name)
#   <tag>-rpms-rpc-live.json   what it proved there, per RPC (rpms-rpc-live.v2); its `contract` says whether the
#                              release serves every RPC lib/rpms_rpc/required_rpcs.json names
#
# This reads them and decides, per release, what rpms-rpc does. The tag is made here, with this repository's own
# GITHUB_TOKEN, so no openrpms credential ever writes rpms-rpc; reading openrpms needs OPENRPMS_READ_TOKEN while it
# is private. The workflow is .github/workflows/openrpms-tags.yml; which pin lives where is openrpms docs/PINS.md.
#
#   ruby tools/openrpms_tags.rb plan   print the plan as JSON ({"todo": [...], "skipped": [...], "refused": [...]});
#                                      exit 1 when any release is refused (each reason printed)
#
# A release is tagged only when every one of these holds; otherwise it is skipped (a record from before the train,
# which names no tag to take) or refused (anything else: the job fails, naming the reason):
#   - the release is published (not a draft or prerelease) and its name is a build tag;
#   - its harness record names this release, a full rpms-rpc commit on `main`, and this release as the tag to take;
#   - its per-RPC record is rpms-rpc-live.v2, names this release and the same rpms-rpc commit, and its contract passed;
#   - no rpms-rpc tag of that name names another commit (a tag is never moved).
module OpenrpmsTags
  OPENRPMS = "lakeraven/openrpms"
  # A build tag: bcer-<RPMS version>-<yyyymmdd>-<openrpms short commit>-<engine>.
  TAG = /\Abcer-\d+\.\d+-\d{8}-[0-9a-f]{7,40}-(ydb|iris)\z/
  COMMIT = /\A[0-9a-f]{40}\z/
  RECORD = "rpms-rpc-live.v2"

  class Error < StandardError; end

  module_function

  def harness_asset(tag) = "#{tag}-harness.json"
  def record_asset(tag) = "#{tag}-rpms-rpc-live.json"

  # The published openrpms releases this may tag, oldest first, from a GitHub releases list: not a draft or a
  # prerelease, named as a build, and carrying both records.
  def candidates(releases)
    Array(releases).select do |r|
      next false unless r.is_a?(Hash) && r["draft"] == false && r["prerelease"] == false && TAG.match?(r["tag_name"].to_s)

      names = Array(r["assets"]).map { |a| a["name"] }
      names.include?(harness_asset(r["tag_name"])) && names.include?(record_asset(r["tag_name"]))
    end.sort_by { |r| r["published_at"].to_s }
  end

  # What to do for release TAG, given its parsed HARNESS and RECORD (nil when not downloaded), whether the harness
  # commit is on rpms-rpc main (ON_MAIN), and the commit an existing rpms-rpc tag TAG names (EXISTING, nil if none).
  # Returns { action: "tag" | "release" | "skip" | "refuse", tag:, commit:, why: }:
  #   tag      create the tag and the release
  #   release  the tag already names this commit; create the release only
  #   skip     a record from before the train (it names no tag to take); not an error
  #   refuse   anything inconsistent; the job fails, naming why
  def decide(tag:, harness:, record:, on_main:, existing: nil)
    h = harness.is_a?(Hash) ? harness["harness"] : nil
    return refuse(tag, nil, "#{harness_asset(tag)} is not a harness record") unless h.is_a?(Hash)

    commit = h["rpms_rpc_commit"]
    unless h.key?("rpms_rpc_tag")
      return { action: "skip", tag: tag, commit: commit, why: "a record from before the train: names rpms-rpc #{commit.to_s[0, 12]} but no tag to take" }
    end

    why = harness_problem(tag, harness, h) || record_problem(tag, commit, record)
    return refuse(tag, commit, why) if why
    return refuse(tag, commit, "rpms-rpc #{commit} is not on main (a cut runs main; RPMS_RPC_REF gates are not tagged)") unless on_main
    return refuse(tag, commit, "rpms-rpc tag #{tag} already names #{existing}, not #{commit}; a tag is never moved") if existing && existing != commit

    { action: existing ? "release" : "tag", tag: tag, commit: commit, why: nil }
  end

  def harness_problem(tag, harness, h)
    return "#{harness_asset(tag)} names release #{harness['release'].inspect}, not #{tag}" unless harness["release"] == tag
    return "#{harness_asset(tag)} names rpms-rpc commit #{h['rpms_rpc_commit'].inspect}, not a full commit" unless COMMIT.match?(h["rpms_rpc_commit"].to_s)
    return "#{harness_asset(tag)} says the commit takes tag #{h['rpms_rpc_tag'].inspect}, not #{tag}" unless h["rpms_rpc_tag"] == tag

    nil
  end

  def record_problem(tag, commit, record)
    file = record_asset(tag)
    return "#{file} is missing or not a JSON object" unless record.is_a?(Hash)
    return "#{file} is #{record['record'].inspect}, not #{RECORD} (no contract verdict to read)" unless record["record"] == RECORD
    return "#{file} names release #{record.dig('release', 'tag').inspect}, not #{tag}" unless record.dig("release", "tag") == tag
    unless record.dig("release", "rpms_rpc", "commit") == commit
      return "#{file} names rpms-rpc #{record.dig('release', 'rpms_rpc', 'commit').inspect}, the harness record #{commit}"
    end

    contract = record["contract"]
    return "#{file} has no contract verdict" unless contract.is_a?(Hash)

    broken = Array(contract["broken"]).map { |b| b.is_a?(Hash) ? "#{b['rpc']} (#{b['why']})" : b.to_s }
    return "#{file}: the contract did not pass#{": #{broken.join(', ')}" unless broken.empty?}" unless contract["pass"] == true && broken.empty?

    nil
  end

  def refuse(tag, commit, why) = { action: "refuse", tag: tag, commit: commit, why: why }

  # --- reading GitHub and git (the plan) ----------------------------------------------------------------------

  def run!(*cmd, what:)
    out, err, status = Open3.capture3(*cmd)
    raise Error, "#{what} failed: #{err.to_s.lines.first.to_s.strip}" unless status.success?

    out
  end

  def gh_json(*args, what:) = JSON.parse(run!("gh", "api", *args, what: what))

  # The decision for every candidate release that has no rpms-rpc release yet.
  # OPENRPMS_TOKEN reads openrpms; the default gh credential reads this repository; GIT_DIR is a checkout of
  # rpms-rpc with main fetched (origin/main).
  def plan(repo:, openrpms_token:, git_dir: Dir.pwd)
    env = { "GH_TOKEN" => openrpms_token }
    out, err, status = Open3.capture3(env, "gh", "api", "--paginate", "--slurp", "repos/#{OPENRPMS}/releases")
    raise Error, "cannot list #{OPENRPMS} releases (gh api: #{err.to_s.lines.first.to_s.strip}); OPENRPMS_READ_TOKEN must read it" unless status.success?

    ours = gh_json("--paginate", "--slurp", "repos/#{repo}/releases", what: "listing #{repo} releases").flatten(1).to_set { |r| r["tag_name"] }
    tags = run!("git", "-C", git_dir, "ls-remote", "--tags", "origin", "refs/tags/bcer-*", what: "listing rpms-rpc tags")
           .lines.to_h { |l| l.split.then { |sha, ref| [ ref.delete_prefix("refs/tags/").delete_suffix("^{}"), sha ] } } # a peeled line follows, and wins

    candidates(JSON.parse(out).flatten(1)).reject { |r| ours.include?(r["tag_name"]) }.map do |r|
      tag = r["tag_name"]
      harness, record = [ harness_asset(tag), record_asset(tag) ].map { |name| asset_json(r, name, env) }
      commit = harness.is_a?(Hash) ? harness.dig("harness", "rpms_rpc_commit").to_s : ""
      on_main = COMMIT.match?(commit) && system("git", "-C", git_dir, "merge-base", "--is-ancestor", commit, "origin/main", err: File::NULL)
      decide(tag: tag, harness: harness, record: record, on_main: on_main, existing: tags[tag])
    end
  end

  # An asset of release R, parsed; nil when it does not parse.
  def asset_json(release, name, env)
    asset = release["assets"].find { |a| a["name"] == name }
    out, _, status = Open3.capture3(env, "gh", "api", "-H", "Accept: application/octet-stream", "repos/#{OPENRPMS}/releases/assets/#{asset['id']}")
    raise Error, "cannot download #{name} from #{OPENRPMS}" unless status.success?

    JSON.parse(out)
  rescue JSON::ParserError
    nil
  end

  def summary(decisions)
    {
      "todo" => decisions.select { |d| %w[tag release].include?(d[:action]) }.map { |d| d.slice(:tag, :commit, :action).transform_keys(&:to_s) },
      "skipped" => decisions.select { |d| d[:action] == "skip" }.map { |d| { "tag" => d[:tag], "why" => d[:why] } },
      "refused" => decisions.select { |d| d[:action] == "refuse" }.map { |d| { "tag" => d[:tag], "why" => d[:why] } }
    }
  end
end

if $PROGRAM_NAME == __FILE__
  abort "usage: ruby tools/openrpms_tags.rb plan" unless ARGV == [ "plan" ]
  token = ENV["OPENRPMS_READ_TOKEN"].to_s
  abort "openrpms_tags: OPENRPMS_READ_TOKEN is not set; #{OpenrpmsTags::OPENRPMS} is private and GITHUB_TOKEN cannot read it" if token.empty?

  begin
    s = OpenrpmsTags.summary(OpenrpmsTags.plan(repo: ENV.fetch("GITHUB_REPOSITORY", "lakeraven/rpms-rpc"), openrpms_token: token))
  rescue OpenrpmsTags::Error => e
    abort "openrpms_tags: #{e.message}"
  end
  puts JSON.pretty_generate(s)
  if (out = ENV["GITHUB_OUTPUT"].to_s) != ""
    File.open(out, "a") { |f| f.puts "todo=#{JSON.generate(s['todo'])}" }
  end
  s["skipped"].each { |d| warn "skip #{d['tag']}: #{d['why']}" }
  s["refused"].each { |d| puts "::error title=Not tagged #{d['tag']}::#{d['why']}" }
  exit 1 unless s["refused"].empty?

  puts "EXPLICIT SUCCESS: #{s['todo'].size} release(s) to tag, #{s['skipped'].size} from before the train skipped, none refused"
end
