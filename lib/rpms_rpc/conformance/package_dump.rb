# frozen_string_literal: true

module RpmsRpc
  module Conformance
    # Parses a PACKAGE #9.4 capture (rpms-ops bin/capture.sh) into the
    # Fingerprint `packages` face: { name => version }.
    #
    # The capture's M loop writes, per entry:
    #
    #   W $P(N,"^",2),"^",$P(N,"^"),"^",$$VERSION^XPDUTL($P(N,"^")),!
    #
    # The #9.4 0-node is NAME^PREFIX^..., so each line is PREFIX^NAME^VERSION
    # (e.g. "AG^IHS PATIENT REGISTRATION^7.2"). Parsing is defensive against
    # session noise in the raw capture: blank lines and bare "RPMS>" prompt
    # lines carry no caret and are skipped, and a missing version (XPDUTL
    # returns "" for version-less packages like %Z^UTILITIES^) is kept as ""
    # — "installed, version unknown" — rather than dropping the package.
    module PackageDump
      module_function

      # Parse dump text into a name-sorted { name => version } hash.
      def parse(text)
        packages = {}
        text.each_line do |line|
          line = line.chomp
          next unless line.include?("^") # blank lines, "RPMS>" prompts

          _prefix, name, version = line.split("^")
          next if name.nil? || name.empty?

          packages[name] = version.to_s
        end
        packages.sort.to_h
      end

      def parse_file(path)
        parse(File.read(path))
      end
    end
  end
end
