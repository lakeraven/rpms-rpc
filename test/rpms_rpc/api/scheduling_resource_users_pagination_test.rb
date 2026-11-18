# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# Synthetic wire regression, not captured replies or live FileMan proof.
# BSDX RESOURCE USER's B index repeats the resource pointer for each member.
# A flat FROM resumes beyond that value, losing the rest of a duplicate group.
# The # traversal uses unique record numbers instead (also exercised by
# test/live/coverage_write_live_test.rb with FROM=(ien-1), XREF="#").
class SchedulingResourceUsersPaginationTest < Minitest::Test
  class MembershipClient
    attr_reader :calls

    def initialize(count)
      @calls = []
      @rows = [ [ 1, 1, 900, "OTHER,BEFORE", 0, 0, 0, 0 ] ]
      count.times do |index|
        @rows << [ index + 2, 7, 1000 + index, format("MEMBER,%03d", count - index), 1, 0, 1, 0 ]
      end
      @rows << [ count + 2, 9, 901, "OTHER,AFTER", 0, 0, 0, 0 ]
    end

    def with_context(_name)
      yield
    end

    def call_rpc(rpc, params)
      raise "Unexpected RPC #{rpc}" unless rpc == "DDR LISTER"
      raise "Unexpected file #{params['FILE']}" unless params["FILE"] == "9002018.15"
      raise "Unexpected paging loop" if @calls.length > 10

      @calls << params
      # LIST^DIC's default B traversal uses .01 (resource pointer). Its
      # secondary IEN disambiguates duplicates, but a flat FROM lacks it.
      column = params["XREF"] == "#" ? 0 : 1
      rows = @rows.sort_by { |row| [ row[column], row[0] ] }
      rows = rows.select { |row| row[column] > params["FROM"].to_i } if params["FROM"]
      page = rows.take(Integer(params.fetch("MAX")))
      reply = []
      if rows.length > page.length
        last = page.last
        reply.concat([ "[Misc]", "MORE^#{last[column]}^#{last[0]}" ])
      end
      reply + [ "[Data]" ] + page.map { |row| row.join("^") }
    end
  end

  def teardown = RpmsRpc.reset!

  [ 100, 101, 205 ].each do |count|
    define_method("test_all_#{count}_members_survive_page_boundaries_and_other_resources_are_excluded") do
      client = MembershipClient.new(count)
      RpmsRpc.configure { |config| config.client = client }

      users = RpmsRpc::SchedulingSetup.resource_users(7)

      assert_equal count, users.length, "A repeated resource pointer must not truncate a membership page"
      assert_equal (2..count + 1).to_a, users.map { |user| user[:id] }.sort
      assert_equal (1000...1000 + count).to_a, users.map { |user| user[:duz] }.sort
      assert_equal users.map { |user| user[:name] }.sort, users.map { |user| user[:name] }
      assert users.all? { |user| user[:overbook] && !user[:modify_schedule] && user[:modify_appointments] && !user[:master_overbook] }
      assert client.calls.all? { |params| params["XREF"] == "#" }
      assert_equal [ nil, "100", *(count > 198 ? [ "200" ] : []) ], client.calls.map { |params| params["FROM"] }
    end
  end
end
