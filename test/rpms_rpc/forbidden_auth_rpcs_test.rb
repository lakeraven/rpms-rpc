# frozen_string_literal: true

require "minitest/autorun"

# BGU's sign-on RPCs must never become our sign-on path.
#
# This is a guard, not a style rule, so it is a test rather than a comment: the
# defect it prevents is invisible at the call site and the RPC name looks like
# an ordinary alternative to XUS AV CODE.
class ForbiddenAuthRpcsTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  # These eight BGU RPCs sit in the CIAV VUECENTRIC context, the one the CIA
  # client signs on under, so context separation does not keep them out of
  # reach: this test does. Sign on with XUS AV CODE (client.rb) or CIANBRPC
  # AUTH (cia_client.rb), which bind DUZ(0) from the user's own record after
  # the credentials are checked. The reason for each is tracked privately
  # (openrpms#655).
  FORBIDDEN = [
    "BGU AVLOGON",
    "BGU ACCESSCODE CHANGE",
    "BGU VERIFYCODE CHANGE",
    "BGU APICALL",
    "BGU RPCCALL",
    "BGU FILER",
    "BGU ROUTINE FILER",
    "BGU CREATERECORD"
  ].freeze

  def test_no_bgu_sign_on_rpc_is_referenced_anywhere_in_lib
    offenders = Dir.glob("#{LIB}/**/*.rb").flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?("#")

        hit = FORBIDDEN.find { |rpc| line.include?(rpc) }
        "#{path.sub("#{LIB}/", "lib/")}:#{i + 1}: #{hit}" if hit
      end
    end

    assert_empty offenders, <<~WHY
      A forbidden BGU RPC is referenced in lib/:

        #{offenders.join("\n  ")}

      This client signs on only with XUS AV CODE or CIANBRPC AUTH.
      See the comment above and openrpms#655.

      Sign on with XUS AV CODE or CIANBRPC AUTH.
    WHY
  end
end
