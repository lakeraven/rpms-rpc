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
  # an altered line. The flag lives on this object. Every non-mutating
  # transform (map, select, reject, +, -, &, |, *, [], slice, first, last,
  # take, drop, reverse, rotate, sort, sort_by, uniq, compact, flatten, zip,
  # each_slice ...) returns a plain Array and drops it, so ask the reply
  # before transforming it, or carry RpmsRpc::Reply.altered?(reply) forward
  # yourself. The gem's own identity-bearing readers (Allergy, Patient.lookup)
  # do that for you and put `altered:` on each row they return.
  #
  # A Reply is FROZEN, along with its lines, and is built only through
  # Reply.from_wire: shifting a header off a reply would leave altered_lines
  # pointing at the wrong row, and appending a raw line would read as
  # unaltered. Build a new one (from_wire(reply.drop(1)) does not keep the
  # flag, from_wire(reply) does) instead of mutating.
  class Reply < Array
    REPLACEMENT = "�"
    # Control characters (and DEL) the CIA reply path has always turned into a
    # space. It is an alteration, so it is reported.
    CONTROL = /[\x00-\x1f\x7f]/

    # Zero-based indexes of the lines that were altered.
    attr_reader :altered_lines

    # A reply that arrives as ONE blob rather than as lines (a GLOBAL ARRAY
    # read, a bare String seed): a String that carries the same flag. It is a
    # String, so every caller that splits, matches or joins it keeps working;
    # String#split and friends return plain Strings and drop the flag, so
    # ask it first (RpmsRpc::Reply.altered?(text)).
    class Text < String
      def altered? = @altered == true
    end

    # lines: the reply's lines, any encoding. controls: true also replaces
    # control characters with a space (the CIA reply grammar). Passing a Reply
    # keeps the alterations it already carries: wrapping an altered reply a
    # second time must never launder the flag.
    def self.from_wire(lines, controls: false)
      altered = lines.is_a?(Reply) ? lines.altered_lines.dup : []
      decoded = Array(lines).each_with_index.map do |line, index|
        next line unless line.is_a?(String)

        text, changed = decode(line, controls)
        altered << index if changed
        text.freeze
      end
      reply = new(decoded)
      reply.instance_variable_set(:@altered_lines, altered.uniq.sort.freeze)
      reply.freeze
    end
    private_class_method :new

    # A blob as valid UTF-8 text with the same flag. A Text passes through
    # unchanged, so it is never decoded (and so never laundered) twice.
    def self.text(raw, controls: false)
      return raw if raw.is_a?(Text)

      decoded, changed = decode(raw.to_s, controls)
      text = Text.new(decoded)
      text.instance_variable_set(:@altered, changed)
      text.freeze
    end

    # True only for a Reply or Text that altered something; false for
    # anything else, including a plain Array or String.
    def self.altered?(reply) = (reply.is_a?(Reply) || reply.is_a?(Text)) && reply.altered?

    # [lines, altered_indexes] for any reply a client can hand back: a Reply,
    # a plain Array, a Text, a plain String or nil. The lines are a plain
    # Array of valid UTF-8 Strings; the indexes name the ones whose text was
    # replaced. For a blob (Text) the replacement character is the evidence:
    # a line holding it counts as altered whenever the blob was, which also
    # flags a literal U+FFFD in stored data beside a real alteration. That
    # errs toward "altered", the safe way.
    def self.lines_with_altered(response)
      case response
      when nil then [ [], [] ]
      when Reply then [ response.to_a, response.altered_lines ]
      when Array
        reply = from_wire(response)
        [ reply.to_a, reply.altered_lines ]
      else
        blob = text(response)
        lines = blob.split(/\r?\n/)
        altered = blob.altered? ? lines.each_index.select { |i| lines[i].include?(REPLACEMENT) } : []
        [ lines, altered ]
      end
    end

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

    # A copy of a frozen Reply would be an unfrozen Reply holding the same
    # indexes, and shifting a header off it would leave altered_lines pointing
    # at the wrong line. A copy is a plain Array: it says plainly that the flag
    # is not carried (ask the reply first).
    def dup = to_a
    def clone(freeze: nil) = to_a
  end
end
