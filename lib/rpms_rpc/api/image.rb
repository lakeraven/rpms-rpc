# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for imaging studies and viewer handoff. The viewer itself
  # is a desktop component external to RPMS; the gateway issues a token
  # the front-end hands off to whatever viewer is configured.
  # Underlying RPCs: ORWRA IMAGING EXAMS1, MAGG IMAGE LAUNCH TOKEN.
  module Image
    extend self

    # Default token TTL in seconds. Configurable via the keyword on
    # launch_token; callers integrating a viewer with a different policy
    # should pass an explicit ttl_seconds rather than mutate this constant.
    DEFAULT_TTL_SECONDS = 300

    def exams_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.image_exams.fetch_many(dfn.to_s))
    end

    def launch_token(dfn, study_ien, ttl_seconds: DEFAULT_TTL_SECONDS)
      return nil if invalid_id?(dfn) || invalid_id?(study_ien)
      return nil unless valid_ttl?(ttl_seconds)

      token = DataMapper.image_launch_token.fetch_scalar(dfn.to_s, study_ien.to_s)
      return nil if token.nil? || token.to_s.strip.empty?

      {
        token: token.to_s,
        viewer_url: nil,
        expires_at: Time.now + ttl_seconds.to_i
      }
    end

    private

    # A nil/zero/negative TTL would silently yield an already-expired token.
    # Require a positive integer-ish value; reject anything else.
    def valid_ttl?(ttl_seconds)
      return false if ttl_seconds.nil?
      return false unless ttl_seconds.is_a?(Integer) || ttl_seconds.to_s.match?(/\A\d+\z/)

      ttl_seconds.to_i.positive?
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
