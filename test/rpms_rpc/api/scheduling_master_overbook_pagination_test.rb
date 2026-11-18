# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# Synthetic wire regression, not captured replies or live FileMan proof.
# BSDX RESOURCE USER's default B index repeats .01 (the resource pointer).
# A flat FROM cannot resume within that duplicate group without FROM("IEN").
# XREF="#" traverses unique IENs, as existing clinic_stops pagination does.
class SchedulingMasterOverbookPaginationTest < Minitest::Test
  class MembershipClient
    attr_reader :calls

    def initialize(master_index: nil, other_resource_master: false)
      @calls = []
      @rows = [ [ 1, 1, 900, 0 ] ]
      205.times do |index|
        @rows << [ index + 2, 7, 1000 + index, index == master_index ? 1 : 0 ]
      end
      @rows << [ 207, 9, 1204, other_resource_master ? 1 : 0 ]
    end

    def with_context(_name)
      yield
    end

    def call_rpc(rpc, params)
      raise "Unexpected RPC #{rpc}" unless rpc == "DDR LISTER"
      raise "Unexpected file" unless params["FILE"] == "9002018.15"
      raise "Unexpected fields" unless params["FIELDS"] == "@;.01I;.02I;.06I"
      raise "Unexpected paging loop" if @calls.length > 10

      @calls << params
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

  [ 99, 100, 205 ].each do |position|
    define_method("test_member_#{position}_retains_master_overbook_right_across_page_boundaries") do
      client = use(master_index: position - 1)

      assert RpmsRpc::SchedulingSetup.master_overbook?(resource_id: 7, duz: 999 + position),
             "Member #{position} has .06=1 even when its resource pointer repeats across a page boundary"
      if position >= 100
        assert client.calls.all? { |params| params["XREF"] == "#" }
        assert_equal [ nil, "100", "200" ], client.calls.map { |params| params["FROM"] }
      end
    end
  end

  def test_a_member_without_master_right_is_not_granted_it
    use

    refute RpmsRpc::SchedulingSetup.master_overbook?(resource_id: 7, duz: 1204)
  end

  def test_the_same_users_master_right_on_another_resource_does_not_grant_it_here
    use(other_resource_master: true)

    refute RpmsRpc::SchedulingSetup.master_overbook?(resource_id: 7, duz: 1204)
  end

  def test_another_users_master_right_on_this_resource_does_not_grant_it
    use(master_index: 204)

    refute RpmsRpc::SchedulingSetup.master_overbook?(resource_id: 7, duz: 1000)
  end

  private

  def use(**options)
    client = MembershipClient.new(**options)
    RpmsRpc.configure { |config| config.client = client }
    client
  end
end
