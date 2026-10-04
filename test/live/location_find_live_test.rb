# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/location"
require "rpms_rpc/api/ddr_fileman"

# Location.find(ien) reads one HOSPITAL LOCATION (#44) entry with DDR GETS
# ENTRY DATA (GETS^DIQ; GETSC^DDR2): .01 NAME, 1 ABBREVIATION, 2 TYPE (a set
# of codes, read external), 3.5 DIVISION (pointer to #40.8, read external).
# DDR GETS ENTRY DATA and DDR LISTER are in CIAV VUECENTRIC, which the spec
# binds; it reads only.
#
# The spec lists the build's locations with DDR LISTER and checks find
# against each one, so it holds on any build that has a location.
class LocationFindLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"

  def test_find_returns_each_listed_location
    listed = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 44, fields: "@;.01", max: 25)
    end
    refute_nil listed, "DDR LISTER on #44 gave no reply"
    refute listed[:error], "DDR LISTER on #44 answered with errors: #{listed.inspect}"
    refute_empty listed[:entries], "the build has no HOSPITAL LOCATION (#44) entry"

    found = listed[:entries].map do |entry|
      loc = client.with_context(CONTEXT) { RpmsRpc::Location.find(entry[:ien]) }
      refute_nil loc, "Location.find(#{entry[:ien]}) found nothing, but #44 lists it"
      assert_equal %i[ien name abbreviation type division], loc.keys
      assert_equal entry[:ien].to_i, loc[:ien]
      assert_equal entry[:pieces].first, loc[:name]
      loc
    end

    typed = found.select { |l| l[:type] }
    refute_empty typed, "no listed location has a TYPE (#44 field 2)"
    typed.each { |l| refute_match(/\A[A-Z]{1,2}\z/, l[:type], "type should be the external form: #{l.inspect}") }
    puts "\n#{persona}: #{found.first(3).map(&:inspect).join(' ')}"
  end

  def test_an_unknown_or_invalid_ien_is_nil
    [ nil, "", "0", "-1", "abc", "999999999" ].each do |bad|
      assert_nil client.with_context(CONTEXT) { RpmsRpc::Location.find(bad) }, "Location.find(#{bad.inspect})"
    end
  end
end
