# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for TIU note templates. Templates form a tree
  # (roots → items) with each leaf carrying boilerplate text. The
  # boilerplate RPC performs server-side token substitution for
  # patient and visit context.
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

    def boilerplate(template_ien, dfn:, visit_ien:)
      return nil if invalid_id?(template_ien) || invalid_id?(dfn) || invalid_id?(visit_ien)

      DataMapper.template_boilerplate.fetch_text(template_ien.to_s, dfn.to_s, visit_ien.to_s)
    end

    def text(template_ien)
      return nil if invalid_id?(template_ien)

      DataMapper.template_text.fetch_text(template_ien.to_s)
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
