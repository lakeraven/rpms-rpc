# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/organization"
require "rpms_rpc/api/ddr_fileman"

# Organization.find(ien) reads one INSTITUTION (#4) entry with DDR GETS ENTRY
# DATA (GETS^DIQ; GETSC^DDR2): .01 NAME, 99 STATION NUMBER, 1.01 / 1.02
# STREET ADDR. 1 / 2, 1.03 CITY, .02 STATE (pointer to #5, read external),
# 1.04 ZIP. File #4 has no phone field, so phone is always nil. DDR GETS
# ENTRY DATA and DDR LISTER are in CIAV VUECENTRIC, which the spec binds; it
# reads only.
#
# The spec checks find against the institutions the build's divisions point
# at (#40.8 field .07: the facility, which carries an address) and against
# the first entries of #4, so it holds on any build with a division.
class OrganizationFindLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"

  def test_find_returns_the_institution_each_division_points_at
    divisions = client.with_context(CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: 40.8, fields: "@;.07I;.07", max: 25)
    end
    refute_nil divisions, "DDR LISTER on #40.8 gave no reply"
    refute divisions[:error], "DDR LISTER on #40.8 answered with errors: #{divisions.inspect}"
    pointed = divisions[:entries].map { |e| e[:pieces] }.reject { |ien, _| ien.to_s.empty? }
    refute_empty pointed, "no MEDICAL CENTER DIVISION (#40.8) points at an institution (field .07)"

    found = pointed.map do |ien, name|
      org = client.with_context(CONTEXT) { RpmsRpc::Organization.find(ien) }
      assert_shape org, ien, name
      org
    end
    assert(found.any? { |o| o[:city] && o[:state] && o[:zip_code] },
           "no division's institution has a city, state and zip (#4 1.03, .02, 1.04): #{found.inspect}")
    puts "\n#{persona}: #{found.first.inspect}"
  end

  def test_find_returns_listed_institutions
    listed = client.with_context(CONTEXT) { RpmsRpc::DdrFileman.lister(file: 4, fields: "@;.01", max: 5) }
    refute_nil listed, "DDR LISTER on #4 gave no reply"
    refute listed[:error], "DDR LISTER on #4 answered with errors: #{listed.inspect}"
    refute_empty listed[:entries], "the build has no INSTITUTION (#4) entry"

    listed[:entries].each do |entry|
      assert_shape client.with_context(CONTEXT) { RpmsRpc::Organization.find(entry[:ien]) },
                   entry[:ien], entry[:pieces].first
    end
  end

  def test_an_unknown_or_invalid_ien_is_nil
    [ nil, "", "0", "-1", "abc", "999999999" ].each do |bad|
      assert_nil client.with_context(CONTEXT) { RpmsRpc::Organization.find(bad) }, "Organization.find(#{bad.inspect})"
    end
  end

  private

  def assert_shape(org, ien, name)
    refute_nil org, "Organization.find(#{ien}) found nothing, but the build lists it"
    assert_equal %i[ien name station_number address city state zip_code phone], org.keys
    assert_equal ien.to_i, org[:ien]
    assert_equal name, org[:name]
    assert_nil org[:phone], "file #4 has no phone field"
  end
end
