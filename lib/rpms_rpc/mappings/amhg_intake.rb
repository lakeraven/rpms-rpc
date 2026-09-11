# frozen_string_literal: true

require_relative "../data_mapper"

module RpmsRpc
  module Mappings
    # INTAKEL^AMHGDA (AMHGDA.m:141). One param: "begin|end|dfn". The third
    # piece is a PATIENT DFN — the loop walks ^AMHRINTK("AE",AMHP,...)
    # (AMHGDA.m:154), the same AE-by-patient shape as VISITL's
    # ^AMHREC("AE",AMHP) (AMHGD.m:24). Not a provider IEN; GROUPL in this
    # same routine is the one that uses piece 3 as a provider.
    #
    # Inverse-date constants (AMHGDA.m:152-153):
    #   AMHIVB = (9999999-AMHB)+.0001
    #   AMHIVE = (9999999-AMHE)-.9999
    # Same pair as TPL/SFL (AMHGD.m:167-168). Opposite of VISITL
    # (+.9999 / -.0001, AMHGD.m:22-23) and of GROUPL in this same
    # routine (AMHGDA.m:107-108). The same from/to does not select
    # equivalently across those lists.
    #
    # No $$ALLOWINT screen — unlike INT^AMHGDINT (AMHGDINT.m:30). An empty
    # result here means the AE range was empty, not that a row was hidden.
    # No type filter: initials and updates both appear as flat rows.
    #
    # Header at AMHGDA.m:148 declares 8 columns; the row at :167 emits 8.
    # No pairs. Program is the VISIT's .02 (AMHGDA.m:161), not the
    # intake's .05. InitialProvider is intake .04 external (:162);
    # PrimaryProvider is the visit primary's name (:164-165). BMXIEN is
    # AMHIEN — the intake IEN.
    DataMapper.define(:amhg_intake_list) do |m|
      m.rpc "AMHG GET INTAKE"
      m.field 0, :ien
      m.field 1, :sort_date          # internal FileMan (intake .01)
      m.field 2, :date               # $$LVDT^AMHGU of the same
      m.field 3, :program            # VISIT .02, not intake .05
      m.field 4, :initial_provider   # intake .04 external
      m.field 5, :visit_ien
      m.field 6, :visit_date         # $$LVDT of visit .01
      m.field 7, :primary_provider   # visit primary, name only
    end

    # INT^AMHGDINT (AMHGDINT.m:10). One param: "dfn|program|begin|end".
    # Patient first, then program (external, $$SCI^AMHGT at :18), then
    # FileMan dates. NOT an intake IEN — ASSESS^AMHGDINT in this same
    # routine is the one that takes an intake IEN despite being named
    # GET VISIT ASSESSMENT (AMHGDINT.m:110). Argument order is also the
    # reverse of INTAKEL's begin|end|dfn.
    #
    # Dates are DIRECT FileMan compares (AMHGDINT.m:34-35), not inverse.
    # Empty begin/end means unbounded. The filter applies to the INITIAL
    # intake date only; updates ride along with a parent that passed.
    #
    # The header is built across TWO SETs (AMHGDINT.m:22-23): 13 columns
    # ending in a trailing caret, then UserUpdate and DateofLastUpdate.
    # Fifteen columns, not the 13 a single-line read shows. Initial row
    # at :55 and update row at :71 both emit 15.
    #
    # Rows are screened per-user by $$ALLOWINT^AMHLEIV(DUZ,AMHXI)
    # (AMHGDINT.m:30). An absent document is not evidence it does not
    # exist. Only type "I" parents are walked (:32); updates come from
    # the AI xref (:57). Program filter (:31) skips a parent whose .05
    # is set and does not match AMHPRGI; an empty .05 always passes.
    #
    # R="~" is set at :13 and unused. Provider IEN (IPIen, .04 "I") and
    # name are separate columns, not a tilde pair. Signed is "Y"/"N"
    # from field .11 (AMHGDINT.m:52), not the inverted "*" VISITL uses.
    #
    # UpdIen is field .13 "I" (AMHGDINT.m:49) — the entering user — not
    # an update-record IEN. DateofLastUpdate is .07 "I" (internal
    # FileMan, :51); DateInitial/DateUpdate are $$LVDT display.
    #
    # BMXIEN is the current record's IEN (AMHXI on initials, AMHY on
    # updates). The addressable intake IEN is on the wire.
    DataMapper.define(:amhg_intake_documents) do |m|
      m.rpc "AMHG GET INTAKE DOCUMENTS"
      m.field 0,  :ien
      m.field 1,  :type                 # "I" or "U"
      m.field 2,  :visit_ien            # AMHREC — $P(0),U,3
      m.field 3,  :date_initial         # $$LVDT; blank on updates
      m.field 4,  :program              # intake .05; blank on updates
      m.field 5,  :provider_initial     # .04 external; blank on updates
      m.field 6,  :date_update          # $$LVDT; blank on initials
      m.field 7,  :provider_update      # .04 external; blank on initials
      m.field 8,  :signed_flag          # "Y"/"N" — AMHGDINT.m:52
      m.field 9,  :provider_ien         # IPIen — .04 "I" of THIS record
      m.field 10, :entered_by_ien       # UpdIen — .13 "I", not an update ien
      m.field 11, :initial_intake_ien   # parent IEN on updates
      m.field 12, :update_program       # .05 on updates; blank on initials
      m.field 13, :last_update_user_ien # UserUpdate — .06 "I"
      m.field 14, :last_update_date     # .07 "I" — internal FileMan
    end
  end
end
