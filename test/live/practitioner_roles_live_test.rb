# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/practitioner"
require "rpms_rpc/api/ddr_fileman"

# Practitioner.roles(duz) reads one user's roles (#167): the divisions and USR
# CLASS memberships TIU DIV AND CLASS INFO answers (USERINFO^TIUSRVT1, in OR
# CPRS GUI CHART), and the user's NAME, PROVIDER CLASS and SERVICE/SECTION
# with DDR GETS ENTRY DATA (in CIAV VUECENTRIC). It reads only.
#
# The spec lists the build's users with DDR LISTER and checks roles against
# each one, so it holds on any build that has a user with a division.
class PractitionerRolesLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  KEYS = %i[duz name provider_class service_section divisions user_classes].freeze

  def test_roles_for_each_listed_user
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 200, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #200 gave no reply"
    refute listed[:error], "DDR LISTER on #200 answered with errors: #{listed.inspect}"
    refute_empty listed[:entries], "the build has no NEW PERSON (#200) entry"

    # .5 POSTMASTER and .6 SHARED,MAIL are Kernel's system entries, not
    # people: roles reads whole-number IENs only.
    people = listed[:entries].select { |entry| entry[:ien].to_s.match?(/\A\d+\z/) }
    dangling = []
    found = people.map do |entry|
      roles = RpmsRpc::Practitioner.roles(entry[:ien])
      refute_nil roles, "Practitioner.roles(#{entry[:ien]}) found nothing, but #200 lists it"
      assert_equal KEYS, roles.keys
      assert_equal entry[:ien].to_i, roles[:duz]
      assert_equal entry[:pieces].first, roles[:name]
      { 4 => roles[:divisions], 8930 => roles[:user_classes] }.each do |file, list|
        list.each do |r|
          assert r[:ien].positive?, "#{entry[:ien]}: a role with no IEN: #{r.inspect}"
          next if r[:name]

          # A nil name is a pointer to no entry, never a read that failed.
          got = client.with_context(CONTEXT) { RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{r[:ien]},", fields: ".01") }
          assert got[:error], "#{entry[:ien]}: #{r.inspect} has no name, but ##{file} entry #{r[:ien]} exists"
          dangling << "user #{entry[:ien]} -> ##{file} #{r[:ien]}"
        end
      end
      assert_includes roles[:user_classes].map { |c| c[:name] }, "USER", "every user is a member of USER (USRLM.m:6)"
      roles
    end

    with_division = found.select { |r| r[:divisions].any? }
    refute_empty with_division, "no listed user has a DIVISION (#200 field 16)"
    puts "\n#{persona}: #{with_division.first(2).map(&:inspect).join(' ')}"
    puts "#{persona}: pointers to no entry (name nil): #{dangling.join(', ')}" if dangling.any?
  end

  def test_the_signed_on_user_has_the_division_it_signed_on_to
    roles = RpmsRpc::Practitioner.roles(client.duz)
    refute_nil roles, "Practitioner.roles(#{client.duz}) found the signed-on user nowhere"
    refute_empty roles[:divisions], "#{persona} (DUZ #{client.duz}) signed on but has no DIVISION"
  end

  def test_an_unknown_or_invalid_ien_is_nil
    [ nil, "", "0", "-1", "abc", "999999999" ].each do |bad|
      assert_nil RpmsRpc::Practitioner.roles(bad), "Practitioner.roles(#{bad.inspect})"
    end
  end
end
