# frozen_string_literal: true

require_relative "agg"

module RpmsRpc
  # The Patient Registration GUI's lookups around a window (AGG, under
  # AGGRPC): the package version it checks at start-up, whether the
  # division's registration parameters are complete, the reports it offers,
  # the entries a table field picks from, the window definition, and whether
  # the user holds a key a button needs. Reads only.
  module Agg
    VERSION_INFO_RPC = "AGG VERSION INFO"
    CHECK_DIVISION_RPC = "AGG CHECK DIVISION"
    REPORT_LIST_RPC = "AGG REPORT LIST"
    WINDOW_TABLE_RPC = "AGG GET WINDOW DEF TABLE"
    WINDOW_DEFINITION_RPC = "AGG GET WINDOW DEFINITION"
    VALIDATE_KEY_RPC = "AGG VALIDATE KEY"

    # EN^AGGVER: the installed version of a package (#9.4 by namespace) and
    # its last patch, with the GUI and RPMS test versions the package pins.
    # nil when no row comes back.
    def version_info(package = "AG", client: RpmsRpc.client)
      record = agg_records(client, VERSION_INFO_RPC, package.to_s).first
      return nil if record.nil? || record[:pkg].to_s.empty?

      { package: record[:pkg], version: record[:maj_ver], version_date: agg_fm_date(record[:maj_dt]),
        last_patch: record[:patch_last], patch_date: agg_fm_date(record[:patch_dt]),
        gui_test_version: agg_presence(record[:gui_test_version]), rpms_test_version: agg_presence(record[:rpms_test_version]) }
    end
    shape :version_info, resource: "agg", verb: "GET", path: "/agg/version-info"

    # REG^AGGVER: whether the signed-on division's REGISTRATION PARAMETERS
    # (#9009061) entry has every field the GUI needs. { complete: true } or
    # { complete: false, message: } with the package's text.
    def division_parameters(client: RpmsRpc.client)
      record = agg_records(client, CHECK_DIVISION_RPC, "").first
      return nil if record.nil?

      record[:result].to_s == "1" ? { complete: true } : { complete: false, message: agg_presence(record[:msg]) }
    end
    shape :division_parameters, resource: "agg", verb: "GET", path: "/agg/division-parameters"

    # EN^AGGRRPT: the reports the GUI's Reports menu lists, each with the RPC
    # that runs it.
    def reports(client: RpmsRpc.client)
      agg_records(client, REPORT_LIST_RPC, "").map do |r|
        { name: r[:report_name], rpc: r[:rpc], definition: agg_presence(r[:definition]), display_type: agg_presence(r[:display_type]),
          report_type: agg_presence(r[:report_type]) }
      end
    end
    shape :reports, resource: "agg", verb: "GET", path: "/agg/reports"

    # TAB^AGGWTBLK: every entry of a file a window's table field picks from,
    # as { ien:, name: } (the second column, read by position).
    def table_entries(file, client: RpmsRpc.client)
      reply = in_context(client) { parse_reply(call_array(client, WINDOW_TABLE_RPC, file.to_s)) }
      return [] if reply.nil?

      reply[:rows].map { |pieces| { ien: pieces[0].to_i, name: pieces[1].to_s } }
    end
    shape :table_entries, resource: "agg", verb: "GET", path: "/agg/files/{file}/table-entries"

    # EN^AGGWDEF: the definition of a registration window, by its name
    # ("Mini Registration") or its #9009068.3 number: one row per field, with
    # the RPCs that display, edit, trigger and validate it. Each row is the
    # reply's columns by name; [] for a window not on file.
    def window_definition(window, client: RpmsRpc.client)
      agg_records(client, WINDOW_DEFINITION_RPC, window.to_s, "").map { |r| r.transform_values { |v| agg_presence(v) } }
    end
    shape :window_definition, resource: "agg", verb: "GET", path: "/agg/window-definition"

    # KEYCHK^AGGULSC: whether the signed-on user holds a security key, as the
    # GUI asks before it enables a supervisor's button. { held: true } or
    # { held: false, message: }.
    def key_held(key, client: RpmsRpc.client)
      record = agg_records(client, VALIDATE_KEY_RPC, key.to_s).first
      return nil if record.nil?

      record[:result].to_s == "1" ? { held: true } : { held: false, message: agg_presence(record[:msg]) }
    end
    shape :key_held, resource: "agg", verb: "GET", path: "/agg/key-held"

    private

    def agg_records(client, rpc_name, *params)
      reply = in_context(client) { parse_reply(call_array(client, rpc_name, *params)) }
      reply ? reply[:records] : []
    end

    def agg_presence(value) = value.to_s.empty? ? nil : value.to_s

    def agg_fm_date(value)
      text = value.to_s
      text.empty? ? nil : FilemanDateParser.parse_date(text.split(".").first)
    end
  end
end
