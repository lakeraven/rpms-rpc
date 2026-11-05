# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
require_relative "../shape"

module RpmsRpc
  # BGU MAILMAN MESSAGE (EN^BGUMAIL). Option: CIAV VUECENTRIC, the only
  # option the pinned build registers this RPC under. EN^BGUMAIL sets
  # BGUARRAY(1)=1 and BGUARRAY(2)="OK" (BGUMAIL.m:6) after the send.
  # The body is one parameter; the routine splits it on $C(175) (BGUMAIL.m:11).
  module Bgu
    extend self
    extend Shape::Declarable

    MAIL_RPC = "BGU MAILMAN MESSAGE"
    CONTEXT = "CIAV VUECENTRIC"
    # $C(175), the separator MAIL^BGUMAIL splits the body on (BGUMAIL.m:11).
    # Byte 175 on the wire.
    C175 = "\xaf"
    # Control characters. In the body, CR and LF are line breaks: they are
    # split out before this runs, then the lines are joined with C175.
    CONTROL = /[[:cntrl:]]/
    # File 3.8 NAME is 3 to 30 characters (CHKGROUP^XMBGRP). Letters, digits,
    # spaces, and the punctuation real groups store (&, -, /). A period is
    # the "G." prefix EN^BGUMAIL adds (BGUMAIL.m:10), not part of the name.
    GROUP_NAME = %r{\A[A-Za-z0-9](?:[A-Za-z0-9 &/-]*[A-Za-z0-9])?\z}

    # Option: CIAV VUECENTRIC. Wire params are body, subject, group
    # (EN(BGUARRAY,BGUDATA,BGUSBJ,BGUGROUP), BGUMAIL.m:3). A multi-line body
    # is one parameter, lines joined by $C(175). $C(175), "^", "|", and a
    # control character in the body or the subject are refused before the
    # call, as is a group name that is not a file 3.8 NAME. Success is the
    # reply "1" then "OK" only. A two-node array and a "1^OK" record are
    # that same answer. Returns { success:, status: } or nil.
    def send_mailman_message(subject:, body:, group:)
      subject_text = subject.to_s
      group_text = group.to_s
      refuse_free_text!(subject_text, "subject")
      body_text = wire_body(body.to_s)
      refuse_group!(group_text)

      raw = in_context do
        RpmsRpc.client.call_rpc(MAIL_RPC, body_text, subject_text, group_text)
      end
      mailman_result(raw)
    end
    shape :send_mailman_message, resource: "bgu", verb: "POST", path: "/bgu/send-mailman-message"

    private

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def wire_body(body)
      lines = body.split(/\r\n|\r|\n/)
      lines.each { |line| refuse_free_text!(line, "body") }
      lines.join(C175)
    end

    def refuse_free_text!(text, which)
      return unless forbidden_free_text?(text)

      raise ArgumentError, "#{which} cannot contain $C(175), a caret, a pipe, or a control character"
    end

    def forbidden_free_text?(text)
      text.include?(C175) || text.include?("^") || text.include?("|") ||
        !text.valid_encoding? || text.match?(CONTROL)
    end

    def refuse_group!(name)
      return if group_name?(name)

      raise ArgumentError, "group must be a mail group name"
    end

    def group_name?(name)
      name.valid_encoding? && name.length.between?(3, 30) && name.match?(GROUP_NAME)
    end

    # A caret row RESULT^STATUS (the mapping seed) and a two-node array
    # ("1", "OK") are the same answer (BGUMAIL.m:6).
    def mailman_result(raw)
      return nil if raw.nil? || raw == "" || (raw.is_a?(Array) && raw.empty?)

      lines = Array(raw).flat_map { |line| line.to_s.split(/\r?\n/) }.map(&:strip).reject(&:empty?)
      return nil if lines.empty?

      result, status = if lines.one? && lines.first.include?("^")
        lines.first.split("^", 2)
      else
        [ lines[0], lines[1].to_s ]
      end
      return nil if result.to_s.empty?

      { success: result == "1" && status == "OK", status: status.to_s }
    end
  end
end
