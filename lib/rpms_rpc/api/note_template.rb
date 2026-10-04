# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for TIU note templates. Templates form a tree
  # (roots → items) with each leaf carrying boilerplate text.
  # {boilerplate} returns that text unexpanded; {text} expands its
  # |FIELD| objects for a patient and visit, server-side.
  #
  # Underlying RPCs: TIU TEMPLATE GETROOTS, GETITEMS, GETBOIL,
  # GETTEXT, ACCESS LEVEL.
  module NoteTemplate
    extend self

    def roots(user_duz)
      return [] if invalid_id?(user_duz)

      Array(DataMapper.template_roots.fetch_many(user_duz.to_s))
    end

    def items(template_ien)
      return [] if invalid_id?(template_ien)

      Array(DataMapper.template_items.fetch_many(template_ien.to_s))
    end

    # A template's UNEXPANDED boilerplate: GETBOIL(TIUY,TIUDA)
    # (TIUSRVT.m:55) takes the template alone and copies its text nodes
    # (TIUSRVT.m:62-64). Expanding |FIELD| objects for a patient is
    # {text}'s job. The old three-actual frame died in M (#219).
    def boilerplate(template_ien)
      return nil if invalid_id?(template_ien)

      DataMapper.template_boilerplate.fetch_text(template_ien.to_s)
    end

    # Expand boilerplate TEXT for a patient and visit — the |FIELD| objects
    # resolved server-side. Underlying RPC: TIU TEMPLATE GETTEXT.
    #
    # Formals: GETTEXT(TIUY,DFN,VSTR,TIUX) (TIUSRVT.m:67-68) — there is no
    # template IEN on this wire. The text arrives as the TIUX list and
    # BLRPLT^TIUSRVD reads it as @ROOT@(n,0) with ROOT="TIUX"
    # (TIUSRVD.m:74,82-83), so each line is sent as TIUX(n,0): a line sent
    # as TIUX(n) expands to nothing. VSTR is passed through to
    # PATVADPT^TIULV only when non-empty (TIUSRVD.m:75). The old
    # template-IEN frame died in M on VSTR (#259).
    #
    # Returns the expanded lines joined, or nil when nothing came back.
    def text(lines, dfn:, visit_string: "")
      return nil if invalid_id?(dfn)

      lines = Array(lines).map(&:to_s)
      return nil if lines.empty?

      tiux = lines.each_with_index.to_h { |line, i| [ [ i + 1, 0 ], line ] }
      DataMapper.template_text.fetch_text(dfn.to_s, visit_string.to_s, tiux)
    end

    def access_level(template_ien, user_duz)
      return nil if invalid_id?(template_ien) || invalid_id?(user_duz)

      DataMapper.template_access_level.fetch_scalar(template_ien.to_s, user_duz.to_s)
    end

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
