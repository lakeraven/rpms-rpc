# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # The site's scheduling setup that decides where an appointment may go: the
  # access types a block can carry, the holidays, and each clinic's booking
  # rules. The BSDX RPCs answer none of these (the scheduling client read them
  # with BMX SQL), so they are read here with the generic FileMan reads DDR
  # LISTER (LISTC^DDR) and DDR GETS ENTRY DATA (GETSC^DDR2). Those are in CIAV
  # VUECENTRIC, not BSDXRPC, and each method binds it for the call and restores
  # the caller's option afterward. Every method only reads.
  #
  # The reply shapes are what a live rpms-ydb 7c3119b build answered the
  # scheduler persona (2026-10-30).
  module SchedulingSetup
    extend self
    extend Shape::Declarable

    CONTEXT = "CIAV VUECENTRIC"

    ACCESS_TYPE_FILE = "9002018.35"
    HOLIDAY_FILE = "40.5"
    HOSPITAL_LOCATION_FILE = 44

    # HOSPITAL LOCATION (#44) fields a booking depends on: 1914 HOUR CLINIC
    # DISPLAY BEGINS, 1918.5 SCHEDULE ON HOLIDAYS? (Y or empty), 2002 MAX # DAYS
    # FOR FUTURE BOOKING, 2500 PROHIBIT ACCESS TO CLINIC? (Y or empty), 2505
    # INACTIVATE DATE, 2506 REACTIVATE DATE, 1916 PRINCIPAL CLINIC.
    CLINIC_FIELDS = { display_begins: "1914", schedule_on_holidays: "1918.5", max_future_days: "2002",
                      prohibit_access: "2500", inactivate_date: "2505", reactivate_date: "2506",
                      principal_clinic: "1916" }.freeze
    # PRIVILEGED USER (#44 field 2501), a multiple of NEW PERSON pointers.
    PRIVILEGED_USER_FILE = "44.04"

    # How many entries one DDR LISTER call asks for; a longer list is read on
    # from the MORE marker.
    PAGE = 100

    # Every BSDX ACCESS TYPE (#9002018.35) with its .01 ACCESS TYPE NAME, .02
    # INACTIVE and .08 PREVENT ACCESS. A block whose access type prevents access
    # takes no appointment (rpms-ux S-SCH-04.2). An unset flag reads as false.
    # Returns [{ id:, name:, inactive:, prevent_access: }], by name. A failed
    # read raises Client::RpcError.
    def access_types
      list(ACCESS_TYPE_FILE, "@;.01;.02I;.08I").map do |entry|
        name, inactive, prevent = entry[:pieces]
        { id: entry[:ien].to_i, name: name, inactive: inactive == "1", prevent_access: prevent == "1" }
      end
    end
    shape :access_types, resource: "appointments", verb: "GET", path: "/appointments/access-types"

    # The HOLIDAY (#40.5) entries from start_date through end_date, by date.
    # Returns [{ date: Date, name: }]. A failed read raises Client::RpcError.
    def holidays(start_date:, end_date:)
      first = fm_date(start_date)
      last = fm_date(end_date)
      # FROM is exclusive (LIST^DIC), so the walk starts one below the first
      # date: 3261101 - 1 is 3261100, which collates just before it.
      entries = list(HOLIDAY_FILE, "@;.01I;2", xref: "B", from: (first - 1).to_s, stop: ->(e) { e[:pieces].first.to_i > last })
      entries.map { |e| { date: FilemanDateParser.parse_date(e[:pieces][0]), name: e[:pieces][1] } }
    end
    shape :holidays, resource: "appointments", verb: "GET", path: "/appointments/holidays"

    # One clinic's booking rules from HOSPITAL LOCATION (#44), by its IEN (the
    # hospital_location_id of a Scheduling.resources row). Returns
    # { id:, display_begins:, schedule_on_holidays:, max_future_days:,
    #   prohibit_access:, privileged_users:, inactivate_date:, reactivate_date: }: display_begins
    # is an hour (0-23) and max_future_days a count, each nil when unset; the
    # dates are Date or nil. privileged_users is the DUZs a clinic that
    # prohibits access lets in: its own PRIVILEGED USERs and its principal
    # clinic's, as RPMS's own scheduling checks them (SDM1.m:33); read only
    # when the clinic prohibits access, [] otherwise.
    # nil for an IEN that is not a number. A failed
    # read, or an IEN with no entry, raises Client::RpcError.
    def clinic_rules(hospital_location_id)
      ien = hospital_location_id.to_s
      return nil unless ien.match?(/\A[1-9]\d*\z/)

      got = in_context do
        DdrFileman.gets_entry(file: HOSPITAL_LOCATION_FILE, iens: "#{ien},", fields: CLINIC_FIELDS.values.join(";"), flags: "I")
      end
      raise Client::RpcError, "DDR GETS ENTRY DATA gave no reply for #44 #{ien}" if got.nil?
      raise Client::RpcError, "DDR GETS ENTRY DATA refused #44 #{ien}" if got[:error]

      value = ->(key) { got[:fields].dig(CLINIC_FIELDS[key], :internal).to_s }
      { id: ien.to_i,
        display_begins: integer_or_nil(value.(:display_begins)),
        schedule_on_holidays: value.(:schedule_on_holidays) == "Y",
        max_future_days: integer_or_nil(value.(:max_future_days)),
        prohibit_access: value.(:prohibit_access) == "Y",
        privileged_users: value.(:prohibit_access) == "Y" ? privileged_users(ien, value.(:principal_clinic)) : [],
        inactivate_date: date_or_nil(value.(:inactivate_date)),
        reactivate_date: date_or_nil(value.(:reactivate_date)) }
    end
    shape :clinic_rules, resource: "appointments", verb: "GET", path: "/appointments/clinic-rules"

    private

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    # Every entry DDR LISTER lists for file, read on from each MORE marker
    # until the list ends or stop says an entry is past the end. A page resumes
    # from the MORE value alone: LIST^DIC takes the IEN half as FROM("IEN"), a
    # subscript a flat DDR list parameter cannot carry, so this is only for
    # indexes whose values are unique (a holiday's date, an access type's name).
    # The PRIVILEGED USERs of the clinic and of its principal clinic, as DUZs.
    def privileged_users(ien, principal)
      [ ien, principal ].select { |c| c.to_s.match?(/\A[1-9]\d*\z/) }.uniq.flat_map do |clinic|
        list(PRIVILEGED_USER_FILE, "@;.01I", iens: ",#{clinic},").map { |e| e[:pieces].first.to_i }
      end.uniq.sort
    end

    def list(file, fields, xref: nil, from: nil, stop: nil, iens: nil)
      out = []
      loop do
        page = in_context do
          DdrFileman.lister(file: file, iens: iens, fields: fields, flags: "IP", max: PAGE, xref: xref, from: from)
        end
        raise Client::RpcError, "DDR LISTER gave no reply for file #{file}" if page.nil?
        raise Client::RpcError, "DDR LISTER refused file #{file}" if page[:error]

        page[:entries].each do |entry|
          return out if stop&.call(entry)

          out << entry
        end
        return out unless page[:more]

        from = page[:more][:value]
      end
    end

    def fm_date(value)
      FilemanDateParser.to_fileman(value.respond_to?(:to_date) ? value.to_date : value).to_i
    end

    def integer_or_nil(text)
      text.match?(/\A\d+\z/) ? text.to_i : nil
    end

    def date_or_nil(text)
      text.empty? ? nil : FilemanDateParser.parse_date(text)
    end
  end
end
