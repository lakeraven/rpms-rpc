# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"
require "rpms_rpc/api/order"

# What VueCentric does around an order once the dialog is open, as the
# provider: it locks the patient for ordering and then the order (ORWDX
# LOCK, ORWDX UNLOCK, ORWDX LOCK ORDER, ORWDX UNLOCK ORDER), asks whether to
# keep the dialog for another order (ORWDX AGAIN), loads a quick order's
# responses (ORWDX LOADRSP), clears its recall cache (ORWDXM2 CLRRCL), runs
# the release-time order checks (ORWDXC SESSION, ORWDXC DISPLAY), and to take
# back an unsigned order checks the action (ORWDXA VALID), lists the reasons
# (ORWDX2 DCREASON, ORWDXA DCREQIEN) and discontinues it (ORWDXA DC).
#
# Writes, and leaves nothing behind: each lock is taken and released in the
# same test, the second session that proves a lock holds is signed out, and
# the one order this spec files is unsigned and is deleted by ORWDXA DC,
# which is read back on ORDER (#100).
class OrderLockAndDiscontinueLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider
  writes!

  DFN = 4 # DEMO,PATIENT ONE; no other live spec orders for this patient
  CLINIC = 3 # DEMO IHS CLINIC
  PSO_OERR = 147 # the outpatient medication dialog
  QUICK_ORDER = 36 # FHW4, a stock diet quick order whose responses point at its own item
  TEXT_DIALOG = "OR GXTEXT WORD PROCESSING ORDER"
  NEW_ORDER = "1" # DC^ORWDXA's ISNEWORD: delete an unsigned order instead of cancelling it

  # LOCK^ORX2 (ORX2.m:22-29): 1, or 0^WHO is editing orders, for a second
  # session while the first holds the lock; UNLOCK releases it.
  def test_the_patient_lock_holds_against_a_second_session_until_released
    assert_equal "1", value("ORWDX LOCK", DFN.to_s)
    other = second_session
    held = pieces(other.call_rpc("ORWDX LOCK", DFN.to_s).first.to_s)
    assert_equal [ "0", "PROFILE,MD is editing orders for this patient." ], held
    assert_equal "1", value("ORWDX UNLOCK", DFN.to_s)
    assert_equal "1", other.call_rpc("ORWDX LOCK", DFN.to_s).first.to_s, "released, the second session gets it"
    assert_equal "1", other.call_rpc("ORWDX UNLOCK", DFN.to_s).first.to_s
  ensure
    client.call_rpc("ORWDX UNLOCK", DFN.to_s)
    other&.disconnect
  end

  # The order's own lock (LOCK1^ORX2, ORX2.m:47-), the order's checks at
  # release, and taking an unsigned order back: VALID answers no reason not
  # to, and DC, told the order is new and unsigned (ISNEWORD, as VueCentric
  # sends it for an order it just saved), deletes it rather than cancel it.
  def test_an_unsigned_order_is_locked_checked_and_discontinued
    order = file_unsigned_order
    id = "#{order};1"

    assert_equal "1", value("ORWDX LOCK ORDER", id)
    other = second_session
    held = pieces(other.call_rpc("ORWDX LOCK ORDER", id).first.to_s)
    assert_equal "0", held[0]
    assert_match(/PROFILE,MD is working on this order/, held[1])
    assert_equal "1", value("ORWDX UNLOCK ORDER", id)
    other.disconnect
    other = nil

    checks = rows("ORWDXC SESSION", DFN.to_s, { "1" => "#{id}^1^1^E" }).map { |r| pieces(r) }
    checks.each { |c| assert_equal id, c[0], "an order check names the order: #{c.inspect}" }
    assert_empty rows("ORWDXA VALID", id, "DC", client.duz.to_s).reject(&:empty?), "an unsigned order may be discontinued"

    reason = value("ORWDXA DCREQIEN")
    reasons = rows("ORWDX2 DCREASON").map { |r| pieces(r.delete_prefix("i")) }
    assert_equal [ "~DCReason" ], reasons.first
    assert_includes reasons, [ reason, "Requesting Physician Cancelled" ], "DCREQIEN is the REQ reason the list offers"

    discontinued = rows("ORWDXA DC", id, client.duz.to_s, CLINIC.to_s, reason, "0", NEW_ORDER)
    assert_equal "~0", pieces(discontinued.first)[0], "a deleted order's row has no IEN (DC^ORWDXA)"
    assert_equal "tDELETED: >> rpms-rpc live spec order to discontinue *UNSIGNED*", discontinued[1], "an unsigned new order is deleted, not cancelled"
    refute on_file?(order), "order #{order} is gone from #100"
    order = nil
  ensure
    other&.disconnect
    rows("ORWDXA DC", "#{order};1", client.duz.to_s, CLINIC.to_s, value("ORWDXA DCREQIEN"), "0", NEW_ORDER) if order && on_file?(order)
  end

  # AGAIN^ORWDX (ORWDX.m:206-208): ORDER DIALOG field 9 (ask for another
  # order) is set.
  def test_ask_for_another_order_follows_the_dialog
    asks = entry("101.41", PSO_OERR, "9").dig("9", :internal)
    assert_equal (asks.to_s.empty? ? "0" : "1"), value("ORWDX AGAIN", PSO_OERR.to_s)
    assert_equal "0", value("ORWDX AGAIN", QUICK_ORDER.to_s), "a quick order sets no such field"
  end

  # LOADRSP^ORWDX (ORWDX.m:39-): a quick order's saved responses,
  # ~PROMPT^INSTANCE^NAME then i(nternal) and e(xternal) rows; the ORDERABLE
  # is an item of the quick order's own display group. CLRRCL^ORWDXM2 clears
  # the recall cache and answers 1.
  def test_quick_order_responses
    got = rows("ORWDX LOADRSP", QUICK_ORDER.to_s)
    at = got.index { |r| r.match?(/\A~\d+\^1\^ORDERABLE\z/) } || flunk("no ORDERABLE response: #{got.inspect}")
    item = got[at + 1].delete_prefix("i")
    filed = entry("101.43", item, ".01;2")
    assert_equal "e#{filed.dig('.01', :external)}", got[at + 2]
    assert_match(/;99ORD\z/, filed.dig("2", :internal), "a diet quick order's item is an ORDER ENTRY item")
    assert_equal "1", value("ORWDXM2 CLRRCL")
  end

  # DISPLAY^ORWDXC (ORWDXC.m:17-): the order checks for a filler namespace
  # when the dialog opens; each row is a check's text.
  def test_order_checks_shown_when_the_dialog_opens
    rows("ORWDXC DISPLAY", DFN.to_s, "PSO").each { |r| refute_empty r.strip }
  end

  private

  # A second broker session as the same user, as a second workstation would be.
  def second_session
    c = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    c.connect
    c.authenticate(*sign_on_pair)
    c
  end

  # One unsigned text order for the patient (ORWDX SAVE), as order_write_live_test.rb files one.
  def file_unsigned_order
    dialog = listed("101.41", ".01").find { |d| d[:pieces][0] == TEXT_DIALOG } || flunk("no #{TEXT_DIALOG} dialog")
    prompts = rows("ORWDX DLGDEF", TEXT_DIALOG).each_with_object({}) { |r, h| name, ien = pieces(r); h[name.to_s.upcase] = ien.to_i if ien.to_s.match?(/\A\d+\z/) }
    comment, start, stop = prompts.values_at("COMMENT", "START", "STOP")
    flunk "#{TEXT_DIALOG} lacks COMMENT/START/STOP prompts: #{prompts.inspect}" unless comment && start && stop
    group = entry("101.41", dialog[:ien], "5").dig("5", :internal)
    responses = { [ start, 1 ] => value("ORWU DT", "NOW"), [ stop, 1 ] => "", [ comment, 1 ] => %(ORDIALOG("WP",#{comment},1)),
                  [ "WP", comment, 1, 1, 0 ] => "rpms-rpc live spec order to discontinue" }
    saved = RpmsRpc::Order.save(DFN, client.duz, CLINIC.to_s, TEXT_DIALOG, responses, display_group: group)
    flunk "Order.save answered #{saved.inspect}" unless saved[:success]
    saved[:ien]
  end

  def on_file?(order)
    got = RpmsRpc::DdrFileman.gets_entry(file: "100", iens: "#{order},", fields: ".02", flags: "I")
    !got.nil? && !got[:error] && !got[:fields].empty?
  end
end
