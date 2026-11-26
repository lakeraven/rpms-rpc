# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../fileman_date_parser"
require_relative "../shape"

module RpmsRpc
  # The BMXNet library's own RPCs (BMX, under BMXRPC), the calls IHS's .NET
  # clients (registration, scheduling, behavioral health, iCare) make around
  # their own: who the user is and which keys and facilities they hold, the
  # library's version, a patient lookup and banner, a patient's recent visits,
  # and the FileMan schema reads and SQL the clients build their tables from.
  # Reads only. Every broker role's row holds BMXRPC (README, Test roles).
  #
  # Values are the text the routines send; a recordset row is a Hash keyed by
  # its typed header's column names, downcased.
  module Bmx
    extend self
    extend Shape::Declarable

    CONTEXT = "BMXRPC"
    USER_RPC = "BMX USER"
    SECURITY_KEY_RPC = "BMX SECURITY KEY"
    FACILITIES_RPC = "BMXGetFacRS"
    VERSION_RPC = "BMX VERSION INFO"
    USER_KEYS_RPC = "BMXUserKeyRS"
    FIND_PATIENT_RPC = "BMX FIND PATIENT"
    FIND_VISIT_RPC = "BMX FIND VISIT"
    IM_HERE_RPC = "BMX IM HERE"
    DEMO_RPC = "BMX DEMO"
    DEMOGRAPHICS_RPC = "BMX PATIENT DEMOG DATA GET"
    CHART_RPC = "BMX PDATA CHART"
    PATIENT_INFO_RPC = "BMXPatientInfoRS"
    PATIENT_LOOKUP_RPC = "BMXPatientLookupRS"
    FIELD_LIST_RPC = "BMX FIELD LIST"
    MULTIPLE_LIST_RPC = "BMX MULT LIST"
    SQL_RPC = "BMX SQL"
    SQL_COLUMNS_RPC = "BMX SQL COLINFO"
    FILE_LIST_RPC = "BMX TLIST"
    FIND_RPC = "BMX FIND"

    # USER^BMXRPC3: the NEW PERSON (#200) name of a user, nil when none.
    def user_name(duz)
      blank(single(USER_RPC, duz.to_s))
    end
    shape :user_name, resource: "bmx", verb: "GET", path: "/users/{duz}/bmx/name"

    # APSEC^BMXRPC3: whether the signed-on user holds a security key (or
    # XUPROGMODE). The routine answers BMXNet's IHSCD_SUCCEEDED, -1, for yes
    # and 0 for no.
    def holds_key?(key)
      single(SECURITY_KEY_RPC, key.to_s) == "-1"
    end
    shape :holds_key?, resource: "bmx", verb: "GET", path: "/bmx/holds-key"

    # GETFCRS^BMXRPC10: the facilities (DIVISION multiple of #200) a user may
    # sign on to, as { name:, ien:, most_recent: }.
    def facilities(duz)
      recordset(FACILITIES_RPC, duz.to_s).map do |r|
        { name: r[:facility_name], ien: r[:facility_ien].to_i, most_recent: r[:most_recent_lookup] == "1" }
      end
    end
    shape :facilities, resource: "bmx", verb: "GET", path: "/users/{duz}/bmx/facilities"

    # BMXVER^BMXRPC8: an installed package's major and minor version and
    # build date, by namespace. nil when the routine answers an error.
    def version(namespace = "BMX")
      row = recordset(VERSION_RPC, namespace.to_s, "").first
      return nil if row.nil? || !row[:error].to_s.empty?

      { major: row[:major_version].to_i, minor: row[:minor_version].to_i, build: blank(row[:build]) }
    end
    shape :version, resource: "bmx", verb: "GET", path: "/bmx/version"

    # USRKEYRS^BMXRPC6: the security key names a user holds.
    def user_keys(duz)
      recordset(USER_KEYS_RPC, duz.to_s).filter_map { |r| blank(r[:key]) }
    end
    shape :user_keys, resource: "bmx", verb: "GET", path: "/users/{duz}/bmx/keys"

    # GETPAT^BMXRPC10: the patients whose name starts with `text` (or whose
    # chart, SSN or DOB matches), as the BMX patient picker lists them.
    def find_patients(text)
      recordset(FIND_PATIENT_RPC, text.to_s).map do |r|
        { dfn: r[:ien].to_i, name: r[:patientname], dob: blank(r[:dob]), sex: blank(r[:sex]), chart: blank(r[:chart]),
          last_update: blank(r[:lastupdate]), classification: blank(r[:classben]), age: r[:age].to_i }
      end
    end
    shape :find_patients, resource: "bmx", verb: "GET", path: "/bmx/patients"

    # GETVIS^BMXRPC10: a patient's most recent visits, newest first, at most
    # `max` (the routine's default is 9). Read by position: the header names
    # nine columns, VISIT_TYPE among them, and each row carries eight, with no
    # visit type.
    def recent_visits(dfn, max: 9)
      table(FIND_VISIT_RPC, "#{dfn}|#{max}").last.map do |line|
        visit, patient, timestamp, location, category, clinic, provider, pov = line.split("^", -1)
        { visit_ien: visit.to_i, dfn: patient.to_i, timestamp: blank(timestamp), location: blank(location),
          service_category: blank(category), clinic: blank(clinic), provider: blank(provider), pov: blank(pov) }
      end
    end
    shape :recent_visits, resource: "bmx", verb: "GET", path: "/patients/{dfn}/bmx/recent-visits"

    # IMHERE^BMXRPC8: the keep-alive a BMX client sends; true when the
    # server answers 1.
    def alive?
      single(IM_HERE_RPC) == "1"
    end
    shape :alive?, resource: "bmx", verb: "GET", path: "/bmx/alive"

    # PDEMO^BMXRPC6: up to `count` patients from `name` on, in name order,
    # with sex and date of birth.
    def patients_from(name, count: 10)
      recordset(DEMO_RPC, name.to_s, count.to_s).map { |r| { name: r[:name], sex: blank(r[:sex]), dob: date(r[:dob]) } }
    end
    shape :patients_from, resource: "bmx", verb: "GET", path: "/bmx/patients-from"

    # PDATA^BMXRPC1: a patient's banner pieces: date of birth, age, sex and
    # chart number in BMX's display forms ("09-Jun-2001", "25 years",
    # "Female", "99-00-17"). nil when the routine answers its error.
    def banner(dfn)
      text = single(DEMOGRAPHICS_RPC, dfn.to_s)
      return nil if text.empty? || text.include?("\x1f")

      dob, age, sex, chart, status = text.split("^", -1)
      { dob: blank(dob), age: blank(age), sex: blank(sex), chart: blank(chart), status: blank(status) }
    end
    shape :banner, resource: "bmx", verb: "GET", path: "/patients/{dfn}/bmx/banner"

    # PDATA^BMXRPC6: the patient with a chart number here: name, date of
    # birth, tribe, address and phones.
    def chart(chart_number)
      row = recordset(CHART_RPC, chart_number.to_s).first
      return nil if row.nil? || row[:name].to_s.empty?

      { chart: row[:chart], name: row[:name], dob: date(row[:dateofbirth]), tribe: blank(row[:tribe]),
        street: blank(row[:street]), city: blank(row[:city]), state: blank(row[:state]), zip: blank(row[:zip]),
        home_phone: blank(row[:homephone]), work_phone: blank(row[:workphone]) }
    end
    shape :chart, resource: "bmx", verb: "GET", path: "/bmx/chart"

    # PTINFORS^BMXRPC4: one patient's name, HRN, date of birth, age, next
    # appointment and sex. The SSN column is not returned.
    def patient_info(dfn)
      row = recordset(PATIENT_INFO_RPC, dfn.to_s).first
      return nil if row.nil? || row[:name].to_s.empty?

      { dfn: row[:ien].to_i, name: row[:name], hrn: blank(row[:hrn]), dob: date(row[:dob]), age: blank(row[:age]),
        next_appointment: blank(row[:next_appt]), sex: blank(row[:sex]) }
    end
    shape :patient_info, resource: "bmx", verb: "GET", path: "/patients/{dfn}/bmx/info"

    # PTLOOKRS^BMXRPC4: the patient lookup by name, HRN or SSN, at most `max`.
    # The SSN column is not returned.
    def patient_lookup(text, max: 10)
      recordset(PATIENT_LOOKUP_RPC, text.to_s, max.to_s).map do |r|
        { dfn: r[:ien].to_i, name: r[:name], hrn: blank(r[:hrn]), dob: date(r[:dob]) }
      end
    end
    shape :patient_lookup, resource: "bmx", verb: "GET", path: "/bmx/patient-lookup"

    # FLDLIST^BMXRPC2: a file's fields as { number:, label: }, labels in BMX's
    # column form (spaces as underscores).
    def fields(file)
      recordset(FIELD_LIST_RPC, file.to_s, "", "").map { |r| { number: r[:number], label: r[:label] } }
    end
    shape :fields, resource: "bmx", verb: "GET", path: "/bmx/files/{file}/fields"

    # MLTLIST^BMXRPC2: a file's multiples (subfiles) as { number:, name: }.
    def multiples(file)
      recordset(MULTIPLE_LIST_RPC, file.to_s, "").map { |r| { number: r[:number], name: r[:name] } }
    end
    shape :multiples, resource: "bmx", verb: "GET", path: "/bmx/files/{file}/multiples"

    # SQL^BMXSQL: BMXNet's FileMan SQL. `sql` is a SELECT over file names
    # and field labels ("SELECT NAME, SEX FROM PATIENT WHERE NAME LIKE 'A%'");
    # each row is keyed by the column names the reply's header carries.
    def sql(sql)
      recordset(SQL_RPC, sql.to_s)
    end
    shape :sql, resource: "bmx", verb: "GET", path: "/bmx/sql"

    # SQLCOL^BMXSQL: the column names a SELECT would answer, without running it.
    def sql_columns(sql)
      header(SQL_COLUMNS_RPC, sql.to_s)
    end
    shape :sql_columns, resource: "bmx", verb: "GET", path: "/bmx/sql-columns"

    # TLIST^BMXSQL: the files, by name from `from` to `to`, the user may read,
    # as { name:, number: }.
    def files(from:, to:)
      recordset(FILE_LIST_RPC, from.to_s, to.to_s).map { |r| { name: r[:file], number: r[:number] } }
    end
    shape :files, resource: "bmx", verb: "GET", path: "/bmx/files"

    # FIND^BMXFIND: the entries of a file whose .01 starts with `text`, at
    # most `max`, each keyed by the reply's column names.
    def find(file, text, fields: ".01", max: 10)
      recordset(FIND_RPC, file.to_s, fields.to_s, "", text.to_s, max.to_s, "", "", "", "")
    end
    shape :find, resource: "bmx", verb: "GET", path: "/bmx/files/{file}"

    private

    def call(rpc_name, *params)
      client = RpmsRpc.client
      ContextScope.scoped(client, CONTEXT) do
        client.respond_to?(:call_rpc_global_array) ? client.call_rpc_global_array(rpc_name, *params) : client.call_rpc(rpc_name, *params)
      end
    end

    def single(rpc_name, *params)
      raw = call(rpc_name, *params)
      text = raw.is_a?(Array) ? raw.join : raw.to_s
      text = text.split("\x00", 2).last if text.include?("\x00")
      text.delete("\x1e").strip
    end

    # The reply's rows after its typed header, keyed by the header's names.
    def recordset(rpc_name, *params)
      names, rows = table(rpc_name, *params)
      rows.map { |row| names.each_with_index.to_h { |name, i| [ name, row.split("^", -1)[i] ] } }
    end

    def header(rpc_name, *params) = table(rpc_name, *params).first.map(&:to_s)

    def table(rpc_name, *params)
      raw = call(rpc_name, *params)
      body = raw.is_a?(Array) ? raw.map { |l| l.to_s.delete("\x1e") }.join("\x1e") : raw.to_s
      body = body.split("\x00", 2).last if body.include?("\x00")
      body = body.split("\x1f", 2).first.to_s
      lines = body.split("\x1e").map { |l| l.delete_prefix("\n").delete_suffix("\r") }.reject(&:empty?)
      return [ [], [] ] if lines.empty?
      raise Client::RpcMError, RpmsRpc.sanitize_error(lines.first) if lines.first.start_with?("ERROR|")

      names = lines.first.split("^", -1).map { |p| (p[/\A[A-Z]\d{5}(.*)\z/m, 1] || p).downcase.to_sym }
      [ names, lines.drop(1) ]
    end

    def blank(value) = value.to_s.empty? ? nil : value.to_s

    def date(text)
      value = text.to_s.strip
      return nil if value.empty?

      Date.strptime(value.gsub(/,\s*/, ", "), "%b %d, %Y")
    rescue Date::Error
      nil
    end
  end
end
