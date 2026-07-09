# frozen_string_literal: true

require_relative "conformance/fingerprint"
require_relative "conformance/package_dump"
require_relative "conformance/package_version"
require_relative "conformance/reader"
require_relative "conformance/classifier"
require_relative "conformance/delta"

module RpmsRpc
  # Declarative conformance probe (docs/conformance/SPEC.md): read an
  # instance's self-describing metadata into a Fingerprint, classify it
  # against reference release rungs, and prescribe the delta to a target
  # release. Never writes to the probed instance.
  module Conformance
  end
end
