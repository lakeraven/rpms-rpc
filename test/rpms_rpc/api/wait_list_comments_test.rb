# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/wait_list"

# WaitList.set_comments refuses a malformed lines: before it reads or sends
# anything, so no client is configured here. The filing itself is proven live
# in test/live/wait_list_comments_live_test.rb.
class WaitListCommentsTest < Minitest::Test
  WL = RpmsRpc::WaitList

  def teardown
    RpmsRpc.reset!
  end

  def test_lines_must_be_a_non_empty_array_of_strings
    [ nil, "one line", [], [ "ok", 2 ] ].each do |lines|
      result = WL.set_comments(list: 1, entry: 1, lines: lines)
      assert_equal :invalid, result[:error], "lines: #{lines.inspect} should be refused: #{result.inspect}"
    end
  end

  def test_a_line_with_a_line_break_is_refused
    [ "a\nb", "a\rb" ].each do |line|
      result = WL.set_comments(list: 1, entry: 1, lines: [ "first", line ])
      assert_equal :invalid, result[:error], "#{line.inspect} should be refused: #{result.inspect}"
    end
  end
end
