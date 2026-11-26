# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"
require "rpms_rpc/api/consult"

# The consult reads VueCentric makes on the Consults tab and while it opens a
# consult order, sent with the parameters the client sends in a recorded
# session and checked against REQUEST/CONSULTATION (#123) and REQUEST
# SERVICES (#123.5): one consult's detail (ORQQCN DETAIL), the services a
# consult may be ordered to (ORQQCN SVC W/SYNONYMS), a service's
# provisional-diagnosis prompt, default reason and prerequisites (ORQQCN
# PROVDX, ORQQCN DEFAULT REQUEST REASON, ORQQCN EDIT DEFAULT REASON, ORQQCN2
# GET PREREQUISITE), the unresolved-consult check (ORQQCN UNRESOLVED) and the
# user's view context (ORQQCN2 GET CONTEXT). Read only.
class ConsultOrderReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 2 # the demo patient with a seeded CARDIOLOGY consult
  TELEHEALTH = 3 # CARE COORDINATION HOME TELEHEALTH on #123.5, with a default reason
  NO_CONSULT = 999_999_999

  # DETAIL^ORQQCN: the consult's display text; its service and requester
  # are #123's TO SERVICE (1) and the order's provider.
  def test_consult_detail_names_its_service_and_requester
    consult = listed("123", ".02;1").find { |e| e[:pieces][0] == DFN.to_s } || flunk("DFN #{DFN} has no consult on #123")
    service = listed("123.5", ".01").find { |s| s[:ien].to_s == consult[:pieces][1] } || flunk("no #123.5 #{consult[:pieces][1]}")
    text = rows("ORQQCN DETAIL", consult[:ien].to_s)
    assert_includes text, "Order Information"
    assert(text.any? { |l| l.match?(/\ATo Service:\s+#{Regexp.escape(service[:pieces][0])}\z/) }, text.first(8).inspect)
    assert(text.any? { |l| l.match?(/\ARequesting Provider:\s+PROFILE,MD\z/) }, "the seed's requester")
    listed_ids = RpmsRpc::Consult.for_patient(DFN).map { |c| c[:ien].to_s }
    assert_includes listed_ids, consult[:ien].to_s, "ORQQCN LIST lists the consult the detail reads"
    assert_empty rows("ORQQCN DETAIL", NO_CONSULT.to_s).reject(&:empty?)
  end

  # SVCSYN^ORQQCN2 (ORQQCN2.m:54-): IEN^NAME^PARENT^HAS CHILDREN^USAGE^
  # ORDERABLE ITEM, from ALL SERVICES down; each a #123.5 service.
  def test_orderable_services_are_request_services
    got = rows("ORQQCN SVC W/SYNONYMS", "1", "1", "1", "0").map { |r| pieces(r) }
    services = listed("123.5", ".01").to_h { |s| [ s[:ien].to_s, s[:pieces][0] ] }
    assert_equal [ "1", "ALL SERVICES", "0", "+" ], got.first[0, 4], "the root, with children"
    got.drop(1).each do |ien, name, parent|
      assert_equal services[ien], name, "service #{ien}"
      assert_equal "1", parent, "#{name} is under ALL SERVICES"
    end
    assert_includes got.map { |r| r[1] }, "CARDIOLOGY"
    got.each { |r| assert_operator r[5].to_i, :>, 0, "#{r[1]} has an orderable item" }
  end

  # PROVDX^ORQQCN2 (GMRCUTL1): the service's provisional diagnosis prompt
  # and how it is entered, PROMPT^METHOD; DEFRFREQ^ORQQCN2: its default
  # reason for request, boilerplate resolved for the patient; EDITDRFR: may
  # the reason be edited (0 unrestricted); PREREQ: its prerequisites, none.
  def test_a_services_order_dialog_defaults
    service = "#{TELEHEALTH};99CON"
    prompt, method = pieces(value("ORQQCN PROVDX", service))
    assert_includes %w[O R S], prompt, "optional, required or suppressed"
    assert_includes %w[F L], method, "free text or lexicon"
    assert_equal [ "Initial Screening for Home Telehealth services." ], rows("ORQQCN DEFAULT REQUEST REASON", service, DFN.to_s, "1")
    assert_equal "0", value("ORQQCN EDIT DEFAULT REASON", service)
    assert_empty rows("ORQQCN2 GET PREREQUISITE", service, DFN.to_s).reject(&:empty?)
    assert_empty rows("ORQQCN DEFAULT REQUEST REASON", "0", DFN.to_s, "1").reject(&:empty?), "no service, no reason"
  end

  # UNRSLVD^ORQQCN2 (ORQQCN2.m:174-181): ANY PENDING for the user and the
  # patient ^ ORWOR SHOW CONSULTS.
  def test_unresolved_consults_and_the_sites_show_parameter
    got = pieces(value("ORQQCN UNRESOLVED", DFN.to_s))
    assert_includes %w[0 1], got[0]
    assert_equal value("ORWU PARAM", "ORWOR SHOW CONSULTS").to_i.to_s, got[1]
  end

  # GETCTXT^ORQQCN2 (ORQQCN2.m:130-132): the ORCH CONTEXT CONSULTS view,
  # BEGIN;END;STATUS;SERVICE; the demo build sets none.
  def test_consult_view_context
    got = value("ORQQCN2 GET CONTEXT", client.duz.to_s)
    assert_equal 4, got.split(";", -1).size, got.inspect
    assert_equal value("ORWU PARAM", "ORCH CONTEXT CONSULTS"), got, "the parameter, read through XPAR"
  end
end
