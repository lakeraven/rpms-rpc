# frozen_string_literal: true

require "minitest/autorun"

# BGU's sign-on RPCs must never become our sign-on path.
#
# This is a guard, not a style rule, so it is a test rather than a comment: the
# defect it prevents is invisible at the call site and the RPC name looks like
# an ordinary alternative to XUS AV CODE.
class ForbiddenAuthRpcsTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  # Verified against the built bcer-9.0-ydb baseline, 2026-09-28.
  #
  # BGUXUSRB:19 runs SET1 — which sets DUZ(0)="@", programmer access — at line
  # 19, and does not check the credentials until line 22. The rebuild at :34 is
  # gated on $G(WEB), and WEB is never set: searched all 65,782 routines in the
  # capture, zero SETs (every bare-WEB hit is a label, a formal parameter, or a
  # comment; BGUTCPH:79 is a label whose body sets BGUWEB, a different
  # variable). And even if it were set, XUP:61 reads
  #
  #     S:$G(DUZ(0))'="@" DUZ(0)=$P(Y(0),"^",4)
  #
  # so XU*8.0*284 skips the field-3 load PRECISELY when DUZ(0) is already "@" —
  # which SET1 just made true. There is no configuration in which this
  # self-repairs, and the failure path leaves "@" set too (nothing on CHX
  # touches DUZ(0)).
  #
  # No broker NEWs DUZ per call (XWBPRS:4-5 `N ERR,S,XWBARY K XWB`;
  # CIANBACT:66 `N I,P,XWBAPVER,XQY,CIAQUIT,ALOG,$ET`), so the value survives
  # the RPC that set it. BGUXUSRC:41 then gates the credential-change RPCs on
  # DUZ(0)'["@", which now passes for ANY target user:
  #
  #     I DA'=DUZ,DUZ(0)'["@",DUZ(0)'["#" Q 0
  #
  # i.e. any signed-on user can change any other user's access or verify code.
  #
  # We are clean today only by context. All three RPCs appear in exactly one
  # option's #19.05 multiple — ^DIC(19,10979,...) = "CIAV VUECENTRIC" — and we
  # sign on through OR CPRS GUI CHART / BGMH PROVIDER / BGMH SUPERVISOR. That
  # separation is the whole mitigation, and nothing else enforces it.
  #
  # Use XUS AV CODE (client.rb) or CIANBRPC AUTH (cia_client.rb). Both bind
  # DUZ(0) from the user's own record AFTER the credentials are checked:
  # XUSRB:17 `S DUZ=0,DUZ(0)=""` then XUS1A:41
  # `S DUZ(0)=$P(XUSER(0),U,4)`, unconditional.
  #
  # Tracked: rpms-ops#655.
  # All eight live in that one context. AVLOGON is the sign-on defect above;
  # ACCESSCODE/VERIFYCODE CHANGE are what the leaked "@" unlocks. The other
  # four are here because of what they are, not because of that bug:
  # BGUAPI's APICALL and RPCCALL both end in `X BGUMSG` — they EXECUTE M.
  # Not arbitrary code off the wire (the message must already exist in
  # ^BGUMCD("C",...) and be Active), but FILER, ROUTINE FILER and
  # CREATERECORD are generic writers sitting in the same context, so the
  # write-then-execute chain is a short one. Whether those writers can reach
  # ^BGUMCD is NOT verified — which is a reason to keep all of them out of
  # this client, not a reason to wait.
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

      BGU AVLOGON sets DUZ(0)="@" (programmer access) at BGUXUSRB:19, three
      lines BEFORE it checks the access and verify codes, and never clears it —
      the WEB rebuild is dead code, and XUP:61 would not clear it anyway. Any
      signed-on user can then reset any other user's credentials via
      BGUXUSRC:41. See the comment above and rpms-ops#655.

      Sign on with XUS AV CODE or CIANBRPC AUTH.
    WHY
  end
end
