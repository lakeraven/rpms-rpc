# frozen_string_literal: true

require "digest"
require "json"
require "open3"

# The RPC inventory's client lists (data/rpc_inventory/clients/), written from where each kind of evidence lives:
#
#   rake rpc:inventory_clients CLOUD_RPMS=<dir> OPENRPMS=<dir> LAKERAVEN_EHR=<dir> BPRM_XML=<file>
#
#   vuecentric-observed.tsv  the VueCentric sessions recorded server side: CIA activity-log exports (cloud-rpms
#                            evidence/retained/*/*.txt, scripts/rpms/cia-activity-log.sh) and rpc-trace.sh recordings
#                            (cloud-rpms docs/analyst/rpc-trace/*/, openrpms test/fixtures/client-trace/*/)
#   vuecentric-named.txt     the RPC names the released client's binaries carry (cloud-rpms scripts/shared/client_named_rpcs.tsv)
#   lakeraven-ehr-methods.txt the rpms-rpc public methods lakeraven-ehr's app/, lib/ and config/ call
#   bprm-entry-points.txt    the M entry points (TAG^ROUTINE) BPRM's stored procedures call in process (its
#                            stored-procedure XML); tools/rpc_inventory matches them to each release's registered entry points
#
# Each file's header names its sources: the repository and commit, plus the sha256 of each file read that the commit does
# not pin (a recording kept out of git, the BPRM XML). Same sources, same bytes: nothing reads a clock, rows are byte-sorted.
# Labels never carry an internal stack name (this repository is public): a stack is "YDB stack MMDD".
module RpcInventory
  module Clients
    FILES = %w[vuecentric-observed.tsv vuecentric-named.txt lakeraven-ehr-methods.txt bprm-entry-points.txt].freeze

    class Error < StandardError; end

    module_function

    def sha256(path) = Digest::SHA256.file(path).hexdigest

    def git(dir, *args)
      out, err, st = Open3.capture3("git", "-C", dir, *args)
      raise Error, "git #{args.join(' ')} in #{dir}: #{err.lines.first.to_s.strip}" unless st.success?

      out
    end

    # "lakeraven/cloud-rpms 0123456789ab": the checkout's origin and the last commit that changed paths (relative to it),
    # so a commit elsewhere in that repository leaves the header as it was. Fails when it is not a checkout of repo, or
    # when paths differ from HEAD, since the header would then name a commit that does not hold them.
    def checkout(dir, repo, paths)
      raise Error, "#{dir} is not a directory" unless File.directory?(dir.to_s)

      origin = git(dir, "remote", "get-url", "origin").strip[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?\z}, 1]
      raise Error, "#{dir} is a checkout of #{origin.inspect}, not #{repo}" unless origin == repo

      dirty = git(dir, "status", "--porcelain", "--", *paths)
      raise Error, "#{dir} has uncommitted changes under #{paths.join(', ')}:\n#{dirty}" unless dirty.empty?

      commit = git(dir, "log", "-1", "--format=%H", "HEAD", "--", *paths).strip
      raise Error, "#{dir} has no commit holding #{paths.join(', ')}" if commit.empty?

      "#{repo} #{commit[0, 12]}"
    end

    def tracked?(dir, path) = !git(dir, "ls-files", "--", path).empty?

    # A stack name in its public form: ydb-stack-1016, yotta-0921 -> "YDB stack 1016", "YDB stack 0921".
    def public_label(text)
      text.gsub(/\b(ydb|iris)-stack-(\d{4})\b/i) { "#{Regexp.last_match(1).upcase} stack #{Regexp.last_match(2)}" }
          .gsub(/\b(yotta|ydb|iris|site)-((?:0[1-9]|1[0-2])\d\d)\b/i) do
            e = Regexp.last_match(1)
            "#{if e.match?(/iris/i) then 'IRIS' elsif e.match?(/site/i) then 'site' else 'YDB' end} stack #{Regexp.last_match(2)}"
          end
    end

    # --- VueCentric observed --------------------------------------------------------------------

    # [ label, { rpc => calls } ] for a CIA activity-log export of the VueCentric application, counting only sessions
    # from a named workstation (an rpms-rpc run shows wid=UNKNOWN); nil for any other export.
    def activity_log(path)
      text = File.read(path, encoding: "UTF-8")
      head = text.match(/^# CIA ACTIVITY LOG export - user (.+?) \(DUZ \d+\), application (.+)$/)
      return nil unless head && head[2].strip == "CIAV VUECENTRIC"

      rpcs = Hash.new(0)
      named = false
      text.each_line(chomp: true) do |line|
        if (s = line.match(/^== SESSION .*\bwid=(\S*)/)) then named = !s[1].empty? && s[1] != "UNKNOWN"
        elsif named && (r = line.match(/^-- \S+ RPC (.+?)\s*$/)) then rpcs[r[1]] += 1
        end
      end
      return nil if rpcs.empty?

      day = File.basename(path)[/(\d{4})(\d\d)(\d\d)T/] && "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}-#{Regexp.last_match(3)}"
      dir = File.basename(File.dirname(path))
      stack = public_label(dir)[/(?:YDB|IRIS|site) stack \d{4}/] || dir
      [ "session on #{stack}, #{head[1]}, #{day}", rpcs ]
    end

    # [ label, { rpc => calls } ] for an rpc-trace.sh recording (MANIFEST.json + calls.jsonl) of VueCentric; else nil.
    def trace(dir)
      manifest = File.join(dir, "MANIFEST.json")
      calls = File.join(dir, "calls.jsonl")
      return nil unless File.file?(manifest) && File.file?(calls)

      m = JSON.parse(File.read(manifest))
      return nil unless m["source"] == "vuecentric"

      rpcs = Hash.new(0)
      File.foreach(calls) do |line|
        next if line.strip.empty?

        c = JSON.parse(line)
        rpcs[c["rpc"]] += 1 if c["kind"] == "rpc"
      end
      [ public_label("#{m['workflow']} on #{m['stack']}, #{m['release']}, #{m['user']}, #{m['first_at'].to_s[0, 10]}"), rpcs ]
    end

    # The observed TSV from a cloud-rpms and an openrpms checkout. The same session can be a full cloud-rpms recording and
    # a trimmed openrpms fixture: per label, the copy with more calls is kept.
    def observed(cloud_rpms, openrpms)
      sources = [ checkout(cloud_rpms, "lakeraven/cloud-rpms", [ "evidence/retained" ]),
                  checkout(openrpms, "lakeraven/openrpms", [ "test/fixtures/client-trace" ]) ]
      found = [] # [ label, rpcs, origin ]
      Dir[File.join(cloud_rpms, "evidence/retained/*/*.txt")].sort.each do |f|
        rec = activity_log(f) or next
        found << [ *rec, f.delete_prefix("#{cloud_rpms}/"), cloud_rpms ]
      end
      Dir[File.join(cloud_rpms, "docs/analyst/rpc-trace/*/")].sort.each do |d|
        rec = trace(d) or next
        found << [ *rec, File.join(d.delete_prefix("#{cloud_rpms}/"), "calls.jsonl"), cloud_rpms ]
      end
      Dir[File.join(openrpms, "test/fixtures/client-trace/*/")].sort.each do |d|
        rec = trace(d) or next
        found << [ *rec, File.join(d.delete_prefix("#{openrpms}/"), "calls.jsonl"), openrpms ]
      end
      kept = found.group_by(&:first).transform_values { |recs| recs.max_by { |r| [ r[1].values.sum, r[2] ] } }
      raise Error, "no VueCentric recording under #{cloud_rpms} or #{openrpms}" if kept.empty?

      # By label, where it was found and its sha256; the path itself carries the internal stack name.
      read = kept.map do |label, (_, _, file, base)|
        where = "#{base == openrpms ? 'openrpms' : 'cloud-rpms'} #{file[%r{\A.*/(?=[^/]+/[^/]+\z)}]}"
        "#{label}: #{where}#{' (not in git)' unless tracked?(base, file)}, sha256 #{sha256(File.join(base, file))}"
      end
      rows = kept.flat_map { |label, (_, rpcs)| rpcs.map { |rpc, n| "#{rpc}\t#{label}\t#{n}" } }.sort_by(&:b)
      header = [
        "RPCs the VueCentric client called in a recorded session: the CIA activity log (#19941.24) exported server side, only",
        "sessions of application CIAV VUECENTRIC from a named workstation. One row per RPC and recording, with its calls.",
        "Written by rake rpc:inventory_clients from #{sources.join(' and ')}:",
        *read.sort.map { |r| "  #{r}" },
        "data/rpc_tiers/observed/ is another session; tools/rpc_inventory sums the calls and counts the sessions across both."
      ]
      "#{header.map { |l| "# #{l}" }.join("\n")}\nrpc\trecording\tcalls\n#{rows.join("\n")}\n"
    end

    # --- VueCentric named -----------------------------------------------------------------------

    NAMED = "scripts/shared/client_named_rpcs.tsv"

    def named(cloud_rpms)
      source = checkout(cloud_rpms, "lakeraven/cloud-rpms", [ NAMED ])
      path = File.join(cloud_rpms, NAMED)
      lines = File.readlines(path, chomp: true)
      release = lines.join("\n")[/client release (\S+?),/, 1]
      names = lines.reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.split("\t").first.strip }.uniq.sort_by(&:b)
      raise Error, "#{path} names no RPC" if names.empty?

      header = [
        "RPC names the released VueCentric client's binaries carry#{" (client release #{release})" if release}: a string scan of",
        "its binaries, #{source} #{NAMED}. The client CAN call these; a recorded session shows which it does.",
        "Written by rake rpc:inventory_clients. One name per line, byte-sorted."
      ]
      "#{header.map { |l| "# #{l}" }.join("\n")}\n#{names.join("\n")}\n"
    end

    # --- lakeraven-ehr --------------------------------------------------------------------------

    EHR_DIRS = %w[app lib config].freeze
    MOD = "(?:::)?RpmsRpc::((?:[A-Z]\\w*)(?:::[A-Z]\\w*)*)"

    # "Module.method" for each rpms-rpc public method a Ruby source calls: RpmsRpc::<Module>.<method> directly, or through
    # a local name bound to the module (a `via: ::RpmsRpc::Scheduling` default, `client = RpmsRpc::Patient`). Comment
    # lines are skipped. Static: a call on a path the app never takes counts; a module reached by reflection does not.
    def calls_in(code)
      code = code.lines.map { |l| l.match?(/\A\s*#/) ? "\n" : l }.join
      aliases = Hash.new { |h, k| h[k] = [] }
      code.scan(/\b(\w+):\s*#{MOD}\b(?!::)/o) { |name, mod| aliases[name] << mod }
      code.scan(/\b(\w+)\s*(?:\|\|)?=\s*#{MOD}\b(?!::|\.)/o) { |name, mod| aliases[name] << mod }
      hits = code.scan(/#{MOD}\.(\w+[?!]?)/o).map { |mod, meth| "#{mod}.#{meth}" }
      aliases.each do |name, mods|
        code.scan(/\b#{Regexp.escape(name)}\.(\w+[?!]?)/).each { |(meth)| mods.uniq.each { |mod| hits << "#{mod}.#{meth}" } }
      end
      hits
    end

    # sending: the "Module.method" keys (RpmsRpc:: dropped) of the public methods that send an RPC (tools/api_coverage).
    def lakeraven_ehr(dir, sending)
      source = checkout(dir, "lakeraven/lakeraven-ehr", EHR_DIRS)
      files = EHR_DIRS.flat_map { |d| Dir[File.join(dir, d, "**/*.rb")] }.sort
      raise Error, "#{dir} has no Ruby under #{EHR_DIRS.join(', ')}" if files.empty?

      known = sending.to_h { |k| [ k, true ] }
      used = files.flat_map { |f| calls_in(File.read(f, encoding: "UTF-8")) }.select { |k| known[k] }.uniq.sort_by(&:b)
      raise Error, "#{dir} calls no rpms-rpc public method that sends an RPC" if used.empty?

      header = [
        "The rpms-rpc public methods lakeraven-ehr calls (#{EHR_DIRS.join('/, ')}/; static), at #{source}, keeping those that",
        "send an RPC. tools/rpc_inventory maps each to the RPCs it sends now. Written by rake rpc:inventory_clients.",
        "One <Module>.<method> per line (RpmsRpc:: dropped), byte-sorted."
      ]
      "#{header.map { |l| "# #{l}" }.join("\n")}\n#{used.join("\n")}\n"
    end

    # --- BPRM -----------------------------------------------------------------------------------

    # TAG^ROUTINE for each M entry point the stored procedures call in process (DO or $$), skipping commented-out lines.
    def entry_points_in(xml)
      xml.each_line.reject { |l| l.match?(%r{\A\s*//}) }.flat_map do |line|
        line.scan(/(?:\$\$|\b[Dd][Oo]?\s+)([A-Z%][A-Z0-9]*)\^([A-Z%][A-Z0-9]+)/).map { |tag, routine| "#{tag}^#{routine}" }
      end.uniq.sort_by(&:b)
    end

    def bprm(path)
      raise Error, "#{path.inspect} is not a file (the BPRM stored-procedure XML)" unless File.file?(path.to_s)

      points = entry_points_in(File.read(path, encoding: "ISO-8859-1").encode("UTF-8"))
      raise Error, "#{path} calls no M entry point" if points.empty?

      header = [
        "BPRM sends no RPC: it queries BMW classes over the SuperServer. Its stored procedures (BMW.BSF.SP.*) call M in",
        "process; these are the entry points (TAG^ROUTINE) they call, DO or $$, from #{File.basename(path)} (sha256",
        "#{sha256(path)}). tools/rpc_inventory marks an RPC whose registered entry point is one of them.",
        "Written by rake rpc:inventory_clients. One entry point per line, byte-sorted."
      ]
      "#{header.map { |l| "# #{l}" }.join("\n")}\n#{points.join("\n")}\n"
    end
  end
end
