# frozen_string_literal: true

require_relative "ddr_fileman"
require_relative "../context_scope"

module RpmsRpc
  module Practitioner
    extend self

    # The option that lists TIU DIV AND CLASS INFO, and the one that lists
    # DDR GETS ENTRY DATA (the pinned build's reach face).
    ROLES_CONTEXT = "OR CPRS GUI CHART"
    FILEMAN_CONTEXT = "CIAV VUECENTRIC"

    # NEW PERSON (#200): .01 NAME, 53.5 PROVIDER CLASS (pointer to #7),
    # 29 SERVICE/SECTION (pointer to #49).
    USER_FIELDS = %w[.01 53.5 29].freeze

    # ORWU USERINFO takes no params and returns the authenticated
    # session user's info, not an arbitrary IEN's. find(ien) succeeds
    # iff ien matches the session user's DUZ; for arbitrary-IEN lookup
    # see rr-fyf — no currently-mapped RPC supports that path.
    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      result = DataMapper.practitioner_info.fetch_one
      return nil if result.nil? || result[:duz].to_i != ien.to_i

      result.merge(ien: result[:duz])
    end

    def search(name_pattern)
      DataMapper.practitioner_list.fetch_many(name_pattern.to_s, "1")
    end

    # The roles RPMS records for one user, by NEW PERSON IEN (#167):
    #
    #   { duz:, name:, provider_class:, service_section:,
    #     divisions: [{ ien:, name: }], user_classes: [{ ien:, name: }] }
    #
    # divisions are the INSTITUTIONs (#4) the user may sign on to, and
    # user_classes the USR CLASSes (#8930) the user is an active member of
    # today, from TIU DIV AND CLASS INFO (see :practitioner_roles). The name,
    # PROVIDER CLASS and SERVICE/SECTION are the user's own fields, and every
    # name is the external form DDR GETS ENTRY DATA reads. A division or class
    # whose name is nil points at no entry: the IEN is what the user's record
    # holds.
    #
    # nil for an invalid or unknown IEN, or no broker reply. USERINFO answers
    # for any number (every number is a member of USER, USRLM.m:6), so the
    # user is read first. An IEN is a positive whole number: Kernel's system
    # entries .5 POSTMASTER and .6 SHARED,MAIL are not people, and answer nil.
    # Binds each RPC's option and restores the caller's.
    def roles(duz)
      return nil unless duz.to_s.match?(/\A\d+\z/) && duz.to_i.positive?

      user, names = nil, {}
      ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        user = DdrFileman.gets_entry(file: 200, iens: "#{duz.to_i},", fields: USER_FIELDS.join(";"), flags: "IE")
      end
      return nil if user.nil? || user[:error]

      field = ->(f) { presence(user[:fields].dig(f, :external)) }
      return nil if field.(".01").nil?

      rows = ContextScope.scoped(RpmsRpc.client, ROLES_CONTEXT) do
        DataMapper.practitioner_roles.fetch_many(duz.to_i.to_s)
      end
      ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        names = { "D" => 4, "C" => 8930 }.to_h do |kind, file|
          [ kind, rows.select { |r| r[:kind] == kind }.map { |r| { ien: r[:ien].to_i, name: entry_name(file, r[:ien]) } } ]
        end
      end

      {
        duz: duz.to_i,
        name: field.(".01"),
        provider_class: field.("53.5"),
        service_section: field.("29"),
        divisions: names["D"],
        user_classes: names["C"]
      }
    end

    private

    # .01 of one entry, external; nil when FileMan has none.
    def entry_name(file, ien)
      got = DdrFileman.gets_entry(file: file, iens: "#{ien.to_i},", fields: ".01", flags: "E")
      got.nil? || got[:error] ? nil : presence(got[:fields].dig(".01", :external))
    end

    def presence(value)
      value.to_s.empty? ? nil : value.to_s
    end
  end
end
