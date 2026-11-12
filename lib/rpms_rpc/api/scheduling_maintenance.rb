# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"
require_relative "../data_mapper"
require_relative "scheduling"
require_relative "scheduling_setup"

module RpmsRpc
  # Windows Scheduling table maintenance: the access types, resource groups
  # and clinic users a site manager keeps (lakeraven-ehr#984, #985), through
  # the BSDX add/edit RPCs the Windows Scheduling client sends. Every one is
  # registered under BSDXRPC only (see Scheduling), so each method binds it
  # for the call and restores the caller's option afterward. Reads of the
  # same files are in SchedulingSetup (DDR LISTER in CIAV VUECENTRIC), which
  # also lists what BSDX RESOURCE GROUPS BY USER would hide from a user
  # without BSDXZMGR.
  #
  # The replies are what a live rpms-ydb 7d0e827 build answered (2026-11-12).
  # Result contract as Scheduling: { success: true, ... }, { success: false,
  # error: }, or nil when the broker gives no reply.
  module SchedulingMaintenance
    extend self
    extend Shape::Declarable

    CONTEXT = Scheduling::CONTEXT

    # Add or change a BSDX ACCESS TYPE (#9002018.35) — BSDX ADD/EDIT ACCESS
    # TYPE (ACCTYP^BSDX14), what Windows Scheduling's table maintenance sends
    # (lakeraven-ehr#985). The routine files .01 NAME, .02 INACTIVE, .05-.07
    # RED, GREEN and BLUE and .08 PREVENT ACCESS, from "IEN|NAME|INACTIVE|
    # COLOR|RED|GREEN|BLUE|PREVENT_ACCESS" with each flag YES or anything else
    # for no; IEN 0 adds. It refuses a second access type of the same name.
    #
    #   id:             the access type to change, or nil to add one
    #   name:           3 to 30 characters (BPRM's rule; FileMan's is 30)
    #   color:          "#RRGGBB", or nil to leave the colour unset
    #
    # A name out of range, or holding "|" or "^", or a colour not "#RRGGBB",
    # raises ArgumentError before anything is sent. The reply is "IEN^-1" on
    # success and "0^BSDX14: <why>" when the routine refuses.
    # Returns { success: true, id: Integer } / { success: false, error: } / nil.
    def save_access_type(name:, id: nil, inactive: false, prevent_access: false, color: nil)
      text = name.to_s.strip
      raise ArgumentError, "an access type name is 3 to 30 characters" unless (3..30).cover?(text.length)
      raise ArgumentError, "an access type name cannot contain | or ^" if text.match?(/[|^[:cntrl:]]/)
      raise ArgumentError, "color must be #RRGGBB" unless color.nil? || color.to_s.match?(/\A#\h{6}\z/)

      rgb = color ? color.delete("#").scan(/../).map { |h| h.hex.to_s } : [ "", "", "" ]
      value = [ id.to_i, text, yes_no(inactive), "", *rgb, yes_no(prevent_access) ].join("|")
      saved_id(in_bsdx { RpmsRpc.client.call_rpc("BSDX ADD/EDIT ACCESS TYPE", value) })
    end
    shape :save_access_type, resource: "appointments", verb: "POST", path: "/appointments/access-type"

    # Add or rename a BSDX RESOURCE GROUP (#9002018.2) — BSDX ADD/EDIT
    # RESOURCE GROUP (ADDRG^BSDX19), from "IEN|NAME", IEN 0 adding. The
    # routine refuses a second group of the same name. A name outside 3 to 30
    # characters (BPRM's rule), or holding "|" or "^", raises ArgumentError
    # before anything is sent. The reply is "IEN^" on success and
    # "0^BSDX19: <why>" when the routine refuses.
    # Returns { success: true, id: Integer } / { success: false, error: } / nil.
    def save_resource_group(name:, id: nil)
      text = name.to_s.strip
      raise ArgumentError, "a resource group name is 3 to 30 characters" unless (3..30).cover?(text.length)
      raise ArgumentError, "a resource group name cannot contain | or ^" if text.match?(/[|^[:cntrl:]]/)

      saved_id(in_bsdx { RpmsRpc.client.call_rpc("BSDX ADD/EDIT RESOURCE GROUP", "#{id.to_i}|#{text}") })
    end
    shape :save_resource_group, resource: "appointments", verb: "POST", path: "/appointments/resource-group"

    # Put a resource in a group — BSDX ADD RES GROUP ITEM (ADDRGI^BSDX20). The
    # reply is "ITEMIEN^-1" on success, "0^0" when the resource is already in
    # the group, and "<ien>^70" for a group or resource no record has.
    # Returns { success: true, id: Integer } (the entry in the group's
    # RESOURCE multiple), { success: false, error: :already_in_group }, or
    # { success: false, error: } / nil.
    def add_resource_group_member(group_id:, resource_id:)
      resp = in_bsdx { RpmsRpc.client.call_rpc("BSDX ADD RES GROUP ITEM", group_id.to_s, resource_id.to_s) }
      return nil if unanswered?(resp)

      row = data_row(resp)
      return { success: false, error: :already_in_group } if row.start_with?("0^0")

      id, code = row.split("^", -1)
      id.to_i.positive? && code == "-1" ? { success: true, id: id.to_i } : { success: false, error: row }
    end
    shape :add_resource_group_member, resource: "appointments", verb: "POST", path: "/appointments/resource-group-member"

    # Take a resource out of a group — BSDX DELETE RES GROUP ITEM
    # (DELRGI^BSDX20), by the entry in the group's RESOURCE multiple. The reply
    # is "GROUPIEN^-1" on success and "<ien>^70" for an entry no record has.
    # Returns { success: true } / { success: false, error: } / nil.
    def remove_resource_group_member(group_id:, item_id:)
      resp = in_bsdx { RpmsRpc.client.call_rpc("BSDX DELETE RES GROUP ITEM", group_id.to_s, item_id.to_s) }
      return nil if unanswered?(resp)

      row = data_row(resp)
      row.split("^", -1)[1] == "-1" ? { success: true } : { success: false, error: row }
    end
    shape :remove_resource_group_member, resource: "appointments", verb: "DELETE", path: "/appointments/resource-group-member"

    # Give a user rights on a clinic's resource, or change them — BSDX
    # ADD/EDIT RESOURCEUSER (ADDRU^BSDX18), from "IEN|OVERBOOK|MODIFY_SCHEDULE|
    # RESOURCEID|USERID|MODIFY_APPOINTMENTS", each right YES or anything else
    # for no. It files BSDX RESOURCE USER (#9002018.15) .01 resource, .02 user,
    # .03 overbook, .04 modify schedule, .05 modify appointments; an add for a
    # user the resource already names edits that entry. The master overbook
    # right (.06) is not among them: SchedulingSetup.set_master_overbook files
    # it. On the built routine a success answers the header alone (BSDX18
    # comments out the "IEN^-1" row the FOIA source has and sets only $C(31)),
    # so the entry is read back with SchedulingSetup.resource_users. A
    # resource or user that is missing answers "<ien>^70". The routine checks
    # only that the resource IEN is a number and files whatever it is given, so
    # a resource BSDX RESOURCES does not list is refused here before the write
    # (ArgumentError).
    # Returns { success: true, id: Integer } / { success: false, error: } / nil.
    def save_resource_user(resource_id:, duz:, overbook: false, modify_schedule: false, modify_appointments: false, id: nil)
      raise ArgumentError, "no BSDX RESOURCE #{resource_id}" unless Scheduling.resources.any? { |r| r[:id] == resource_id.to_i }

      value =[ id.to_i, yes_no(overbook), yes_no(modify_schedule), resource_id.to_i, duz.to_i, yes_no(modify_appointments) ].join("|")
      resp = in_bsdx { RpmsRpc.client.call_rpc("BSDX ADD/EDIT RESOURCEUSER", value) }
      return nil if unanswered?(resp)

      row = data_row(resp)
      return { success: false, error: row } unless row.empty?

      entry = SchedulingSetup.resource_users(resource_id).find { |u| u[:duz] == duz.to_i }
      entry ? { success: true, id: entry[:id] } : { success: false, error: "BSDX ADD/EDIT RESOURCEUSER filed no entry for user #{duz.to_i}" }
    end
    shape :save_resource_user, resource: "appointments", verb: "POST", path: "/appointments/resource-user"

    # Take a user's rights on a resource away — BSDX DELETE RESOURCEUSER
    # (DELRU^BSDX18), by the BSDX RESOURCE USER entry. The reply is "IEN^-1"
    # on success and "<ien>^70" for an entry no record has.
    # Returns { success: true } / { success: false, error: } / nil.
    def remove_resource_user(resource_user_id)
      resp = in_bsdx { RpmsRpc.client.call_rpc("BSDX DELETE RESOURCEUSER", resource_user_id.to_s) }
      return nil if unanswered?(resp)

      row = data_row(resp)
      row.split("^", -1)[1] == "-1" ? { success: true } : { success: false, error: row }
    end
    shape :remove_resource_user, resource: "appointments", verb: "DELETE", path: "/appointments/resource-user"

    private

    def in_bsdx(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def unanswered?(resp)
      resp.nil? || resp == "" || (resp.is_a?(Array) && resp.empty?)
    end

    # The first data row of a BSDX reply, after its column header, with the
    # record separators stripped. An empty string when there is none.
    def data_row(resp)
      Array(resp).map { |l| DataMapper.strip_recordset_separators(l) }
                 .reject { |l| DataMapper.recordset_header_row?(l) }
                 .first.to_s
    end

    def yes_no(flag) = flag ? "YES" : "NO"

    # The "IEN^..." reply of a BSDX add/edit: success when the IEN is positive.
    def saved_id(resp)
      return nil if unanswered?(resp)

      row = data_row(resp)
      id = row.split("^", -1).first.to_i
      id.positive? ? { success: true, id: id } : { success: false, error: row.split("^", -1)[1..].join("^") }
    rescue RpmsRpc::Client::FrameTooLongError => e
      { success: false, error: e.message }
    end
  end
end
