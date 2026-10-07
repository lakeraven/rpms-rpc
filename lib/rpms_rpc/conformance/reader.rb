# frozen_string_literal: true

require_relative "fingerprint"

module RpmsRpc
  module Conformance
    # Adapter interface: every reader emits the same Fingerprint, tagged
    # with backend + access method (docs/conformance/SPEC.md, "Backend
    # adapters"). Readers are read-only by construction — they capture
    # self-describing metadata (file #8994, #9.4, #9.7, DD, BMW.*) and
    # never exercise behavioral RPCs against the target.
    class Reader
      def fingerprint
        raise NotImplementedError, "#{self.class}#fingerprint must be implemented by a Reader subclass"
      end
    end

    # Loads a committed YAML fingerprint (data/fingerprints/*.yml).
    # Build-free: CI and tests probe without any live instance.
    class FixtureReader < Reader
      # A reference file whose first line says so is a hand-authored seed, not
      # a capture of a built release (docs/conformance/CAPTURE.md): it names
      # real RPCs, but nothing was ever pinned from it.
      PLACEHOLDER_MARK = "PLACEHOLDER"

      def self.placeholder?(path)
        File.open(path) { |f| f.gets.to_s.include?(PLACEHOLDER_MARK) }
      end

      # The reference fingerprints a probe ranks against: every *.yml in `dir`,
      # sorted, minus the placeholders. A placeholder would otherwise rank as
      # a rung, and a target can be "classified as" a release nobody captured.
      def self.reference_paths(dir)
        Dir.glob(File.join(dir, "*.yml")).sort.reject { |path| placeholder?(path) }
      end

      def initialize(path)
        super()
        @path = path
      end

      def fingerprint
        Fingerprint.load(@path)
      end
    end

    # Portable live reader — read-only FileMan lister RPCs over Cia/Bmx
    # (allowlist: DDR LISTER, DDR GETS ENTRY DATA, XWB FILE LIST,
    # XWB API LIST, ...). XWB routes to ^XWB(8994) on every VistA-family
    # backend, so this works on IRIS/RPMS, YottaDB/VistA, and WorldVistA
    # alike. Interface only in the first slice.
    class BrokerReader < Reader
      def initialize(client: nil)
        super()
        @client = client
      end

      def fingerprint
        raise NotImplementedError,
              "BrokerReader is interface-only in the first slice " \
              "(follow-up: live capture via read-only FileMan lister RPCs)"
      end
    end

    # IRIS-only live reader — SELECT-only %FileMan.* + system catalog;
    # adds the optional BMW.* face to the fingerprint. Interface only in
    # the first slice.
    class IrisSqlReader < Reader
      def initialize(connection: nil)
        super()
        @connection = connection
      end

      def fingerprint
        raise NotImplementedError,
              "IrisSqlReader is interface-only in the first slice " \
              "(follow-up: live capture via SELECT-only IRIS SQL)"
      end
    end
  end
end
