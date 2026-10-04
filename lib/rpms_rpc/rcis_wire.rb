# frozen_string_literal: true

module RpmsRpc
  # The RCIS (BMC) wire convention (#210), read from BMCRPC2/BMCRPC4 on the
  # built image: a record may start with the sigil "~`", records within one
  # node are separated by "~", and a write answers "~`1^IEN" (success),
  # "~`0^message" (failure) or "~`-1^message" (the duplicate-referral prompt).
  module RcisWire
    SIGIL = "~`"

    # The records in one node, sigils stripped, empty records dropped.
    def self.records(raw)
      raw.to_s.split("~").filter_map do |rec|
        rec = rec.delete_prefix("`")
        rec unless rec.empty?
      end
    end

    # A sigil write result as a Hash, or nil when raw does not carry the sigil.
    def self.result(raw)
      line = raw.to_s.strip
      return nil unless line.start_with?(SIGIL)

      code, value = line.delete_prefix(SIGIL).split("^", 2)
      value = nil if value.to_s.empty?
      if code == "1"
        { success: true, code: code, ien: value, message: nil }
      else
        { success: false, code: code, ien: nil, message: value }
      end
    end
  end
end
