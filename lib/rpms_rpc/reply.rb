# frozen_string_literal: true

module RpmsRpc
  # The lines of one RPC reply, as every client's #call_rpc returns them.
  #
  # An Array of UTF-8 Strings, so every existing caller (first, map, join,
  # indexing) works unchanged. What it adds is one fact a plain Array cannot
  # carry: whether any line had to be altered to become valid UTF-8, and which.
  #
  # CHARSET: assumed UTF-8, UNPROVEN. Latin-1 is observed in stored data
  # (conformance/build_surface.rb, the \xB7 bullet in the bcer-9.0-20260930
  # RPC descriptions; api/patient.rb notes non-UTF-8 name bytes), so real
  # Latin-1 text is replaced and reported as altered. No site or broker
  # character set is documented in this repository; a live read with a known
  # high byte is the follow-up that settles it.
  #
  # Altered text must never read as verified identity. A host that matches on
  # reply text (an allergen name, a patient name) asks #altered? and refuses
  # an altered line. The flag lives on this object: Array#map, #select and
  # #+ return a plain Array and drop it, so ask the reply before transforming
  # it, or carry RpmsRpc::Reply.altered?(reply) forward yourself.
  class Reply < Array
    REPLACEMENT = "�"
    # Control characters (and DEL) the CIA reply path has always turned into a
    # space. It is an alteration, so it is reported.
    CONTROL = /[\x00-\x1f\x7f]/

    # Zero-based indexes of the lines that were altered.
    attr_reader :altered_lines

    # lines: the reply's lines, any encoding. controls: true also replaces
    # control characters with a space (the CIA reply grammar).
    def self.from_wire(lines, controls: false)
      altered = []
      decoded = Array(lines).each_with_index.map do |line, index|
        next line unless line.is_a?(String)

        text, changed = decode(line, controls)
        altered << index if changed
        text
      end
      new(decoded).tap { |reply| reply.instance_variable_set(:@altered_lines, altered.freeze) }
    end

    # True only for a Reply that altered a line; false for anything else.
    def self.altered?(reply) = reply.is_a?(Reply) && reply.altered?

    def self.decode(line, controls)
      text = line.dup.force_encoding(Encoding::UTF_8)
      changed = false
      unless text.valid_encoding?
        text = text.scrub(REPLACEMENT)
        changed = true
      end
      if controls && text.match?(CONTROL)
        text = text.gsub(CONTROL, " ")
        changed = true
      end
      [ text, changed ]
    end
    private_class_method :decode

    def initialize(*)
      super
      @altered_lines = [].freeze
    end

    def altered? = !altered_lines.empty?
  end
end
