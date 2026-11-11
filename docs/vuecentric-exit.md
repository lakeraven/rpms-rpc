# Leaving VueCentric-only RPCs: what the December path needs

**Status:** findings and a work list. Nothing here is built. Read-only analysis of the pinned build `bcer-9.0-20261012-e7923a4-ydb`.
**Why:** rpms-rpc signs on as the VueCentric application (`CIAV VUECENTRIC`) and calls 37 RPCs that sit in no other broker option. The direction is stock RPMS RPCs first, then DDR FILER for FileMan-only changes, otherwise "not supported, done in RPMS". We write no M.

## How the 37 were counted

`lib/rpms_rpc/required_rpcs.json` lists 204 distinct RPCs across 47 modules. Joined against the build's broker-option inventory (`data/inventories/<build>/…-contexts_19_05.txt`):

- 37 RPCs are in `CIAV VUECENTRIC` and no other option.
- 166 are also in another option. 65 of those are also in `CIAV VUECENTRIC`; the other 101 are in package or CPRS options only.
- 1 is in no option (`CIANBRPC CANRUN`, the CIA sign-on RPC).

The build has 52 broker options. `CIAV VUECENTRIC` holds 1,639 RPCs and `OR CPRS GUI CHART` 1,012. The IHS package options each carry their own list (`BSDXRPC` 69, `AGGRPC` 101, `AMHGRPC` 223, `BMXRPC` 59). In all, 102 of the 204 RPCs are in `CIAV VUECENTRIC` (37 only there, 65 shared). The 37 are: `BEHOCACV CWAD`, `BEHOCCD GETREF`, `BEHOCCD PHR`, `BEHOCIR GETNUM`, `BEHOCIR GETTXT`, `BEHOCIR1 GETCCDS`, `BEHOENCX CHKVISIT/FETCH/GETVISIT`, `BEHOPTPC GETBDP`, `BEHOPTPL DOBLKP/HRNLKP/LISTALL/LOOKUP`, `BEHOSICX SITEINFO`, `BEHOVM SAVE/TEMPLATE/VALIDATE`, `BEHOVM2 VUNITS`, `BGOPROB DEL/SET`, `BGOREF GETREA/SET`, `BGOVCPT GET/SET`, `BGOVEXAM SET`, `BGOVHF SET`, `BGOVIMM GET/GETVFC`, `BGOVIMM2 GETELIG`, `BGOVMSR GET/LAST/SET`, `BGOVPOV SET`, `CIAVCXUS HASKEYS/VIMINFO`, `CIAVMCFG GETREG`.

## Class key

- **A** a stock equivalent exists with equivalent behaviour.
- **B** a stock equivalent exists but loses something IHS-specific.
- **C** DDR on named file and fields could do it. FileMan-only is a risk if it bypasses business rules.
- **D** not supported outside VueCentric.
- **E** cannot tell yet.

## The December path

Two routes the first pass missed:

- **Scheduling check-in creates the PCC visit.** `CHECKIN^BSDX25` (RPC `BSDX CHECKIN APPOINTMENT`, option `BSDXRPC`) calls `GETVISIT^BSDAPI4`, and again with `FORCE ADD` when no visit exists, then adds the provider (BSDX25.m lines 132-150). It does so only when the clinic's hospital-location record has its create-visit flag set (file 9009017.2, field .09).
- **The IHS Behavioral Health package saves visits itself.** `AMHG SAVE VISIT` (`VISIT^AMHGSVF`, option `AMHGRPC`) writes the BH record through `MODV^AMHGEVF`. The same routine has `POV`, `PN`, `SCREEN`, `HF`, `MSR` and `ASS` entry points. The RPC names differ from the entry-point tags: `AMHG SAVE POV`, `AMHG SAVE PROGRESS NOTES` (`PN`), `AMHG SAVE SCREENING` (`SCREEN`), `AMHG SAVE HEALTH FACTORS` (`HF`) and `AMHG SAVE MEASUREMENTS` (`MSR`). The inventory registers no RPC for `ASS`. rpms-rpc wraps the BH reads only.

| Need | VueCentric-only RPC used today | Non-VueCentric route | Class | Notes |
|---|---|---|---|---|
| Signed-on user (DUZ) | `CIAVCXUS VIMINFO` | `XUS AV CODE` (DUZ in RET(0)), `XUS GET USER INFO` (option `XUS SIGNON`) | A | Needs the generic XWB or BMX sign-on instead of CIA. Leaving CIA loses the CIA session id; staying on CIA with `application:` set to another option is an alternative, not a verified route (see open points). |
| Security keys | `CIAVCXUS HASKEYS` | `ORWU NPHASKEY` (one call per key), or DDR LISTER on 200.051 | A | Always pass the signed-on DUZ. `ORWU HAS KEY` is not registered in this build. |
| Division and station | `BEHOSICX SITEINFO` | `XUS GET USER INFO` line 3, `XUS DIVISION GET/SET` | A | `XUS DIVISION SET` checks the user's division multiple; `CIANBRPC DIVSET` does not. Address and name by DDR read of file 4. |
| Widget registry | `CIAVMCFG GETREG` | none needed | D | Dumps VueCentric's widget registry. The web app has no use for it. |
| Patient selection | `BEHOPTPL LOOKUP`, `HRNLKP`, `DOBLKP`, `LISTALL` | not chosen; `AGG LOOKUP PATIENTS` (option `AGGRPC`) is a candidate | E | Four of the 37. Read from the inventory only; behaviour not compared. `PatientSelection.find` already mirrors VueCentric's lookup. |
| Banner flags (C, W, A, D) | `BEHOCACV CWAD` | `ORWPT CWAD` (option `OR CPRS GUI CHART`) | A | Same scan; no Patient Record Flag letter "F". |
| Patient Record Flags | `BEHOCACV CWAD` ("F") | `ORPRF HASFLG` (`CIAV VUECENTRIC`, `OR CPRS GUI CHART`), `Patient.flags` | A | A behavioral-health safety flag is a real banner item. Live spec on the demo flag rpms-ops seeds (`test/live/patient_flags_live_test.rb`). |
| Designated provider | `BEHOPTPC GETBDP` | DDR read of IHS PATIENT (#9000001) field .14 (the PCP field, as in `lib/rpms_rpc/mappings/ihs.rb`); `ORWPT1 PRCARE` reads PCMM, which IHS sites do not fill | B | Latent bug: the banner uses the first row of an alphabetical category list. |
| Create the visit | `BEHOENCX FETCH` (create) | Scheduling check-in; `AMHG SAVE VISIT` for BH | A | Depends on the clinic's create-visit flag. Unverified on a running image. `BEHOENPC SAVE` also creates the visit it files onto (see "Filing an encounter" below). |
| Visit diagnosis | `BGOVPOV SET` | `AMHG SAVE POV` for BH visits | A for BH, E otherwise | `BEHOENPC SAVE` files a V POV with its narrative, live-proven; it is in `CIAV VUECENTRIC` only. `ORWPCE SAVE` is not a route (below). |
| Progress notes | (TIU, stock) | `AMHG SAVE PROGRESS NOTES` for BH notes | stock | |
| Screening results | `BGOVHF SET` | `AMHG SAVE SCREENING` | A (probable) | Which store a PHQ-9 or GAD-7 belongs in is unconfirmed. |
| Problem list | `BGOPROB SET/DEL` | `ORQQPL ADD SAVE`, `ORQQPL DELETE` (not taken) | B | Decided (#527): writes stay on `BGOPROB SET/DEL`, which keep SNOMED, laterality and IHS numbering; the gem wraps no `ORQQPL` write. Live-proven by `test/live/problem_write_live_test.rb`. Goes on the exceptions list. |
| Psych CPT | `BEHOENPC SAVE` | none outside `CIAV VUECENTRIC` | D | Decided (#524): `Procedure.add` files through `BEHOENPC SAVE`, not `BGOVCPT SET`, live-proven by `test/live/procedure_add_live_test.rb`. Its CPT line files the code and quantity only. Goes on the exceptions list. |
| Vitals and measurements | `BEHOVM*`, `BGOVMSR*` | `AMHG SAVE MEASUREMENTS` (BH); GMV vitals unchecked | E | Not on the December path. |
| Immunization, refusal, eligibility, PHR | `BGOVIMM*`, `BGOREF*`, `BGOVIMM2 GETELIG`, `BEHOCCD*`, `BEHOCIR*` | none | D or E | Primary care, planned for later. The C-CDA is built in Rails, not from these RPCs. |

## Filing an encounter: `BEHOENPC SAVE`, not `ORWPCE SAVE`

`BEHOENPC SAVE` (`SAVE^BEHOENPC`) files a whole encounter in one call: the visit, V POV with its narrative, V CPT, V HEALTH FACTOR and V PROVIDER, all on that visit.
It is the RPC the released VueCentric client names for an encounter save, and it is registered in `CIAV VUECENTRIC` only.
It takes one list parameter, in the layout `BEHOENPC.m` documents, and answers `0` when it files:

```
HDR^0^^<loc>;<date>;<category>
VST^DT^<date>
VST^PT^<dfn>
VST^HL^<loc>
VST^VC^<category>
PRV^<duz>^^^^1
POV+^<icd>^^^^1^^^^<narrative>
CPT+^<cpt>
HF+^<health factor ien>^^^^<duz>
```

The second and third parameters are "not used (but required)" (`BEHOENPC.m` lines 6-8).
A `+` adds a row; a line without it edits the matching row on the visit; a `-` deletes.
On the same day, clinic and category, it files onto the visit already there (`FNDVIS^BEHOENCX`).

`test/live/encounter_save_behoenpc_live_test.rb` files one encounter this way over the real CIA broker, as the run's persona, and reads every row back with DDR.
It passed on `bcer-9.0-20261109-d3adcff-ydb` as PROFILE,MD (no XUPROGMODE) and as PROV123.
rpms-ops proves the same at build level (`test/encounter_save_build_level.sh`, rpms-ops#1042).
The gem has no wrapper for it yet.

`ORWPCE SAVE`, the CPRS name, is not a route and should not be repointed.
As registered it points at `SAVE^CIAVCXPC`, a routine the image does not carry, and it fails with `%YDB-E-ZLINKFILE`.
Repointed to the stock `SAVE^ORWPCE`, it answers empty and files nothing, because stock PCE asks Visit Tracking for the visit and file 150.9 ships empty.
That road would need new site configuration and at least one more defect fixed, for an RPC nothing calls (rpms-ops#1042, FOIA defects register E8).

Not proven: the behavioral-health path through `AMHG SAVE *` was not compared with it; the list comes from the routine's comments and the build-level test, not from a client trace; vitals, immunizations, skin tests and patient education lines were not exercised; it ran on YottaDB only.

## Verified, and not

Read in the pinned routines (`rpms-ops/data/standup/bcer-9.0-ydb/r/`), not run:
`OPTCHK^CIANBUTL`; `CHECKIN^BSDX25` and `GETVISIT^BSDAPI4` call; `VISIT^AMHGSVF`; the `BGOVCPT` input layout (`Visit IEN ^ CPT IEN ^ DFN ^ Event date ^ Qty ^ Dx ^ Mod1 ^ Prov …`); `GETBDP^BEHOPTPC` and `ALLDP^BDPAPI`.

Since verified live: `BEHOENPC SAVE` files an encounter, and `CIAVCXPC` is not on the image (above).

Not verified: other live behaviour; that `AMHGEVF` links the BH record to a PCC visit; the clinic create-visit flag on the target tenant; what the `AMHG SAVE POV`, `AMHG SAVE SCREENING` and `AMHG SAVE MEASUREMENTS` RPCs accept; the generic-path RPCs under a non-CIA context.

## Open points

- Leaving the VueCentric option does not require leaving CIA: `CiaClient#authenticate` takes `application:` and context switching keeps the session UID. What must change is the `signon_duz` read, which calls `CIAVCXUS VIMINFO`; `XUS GET USER INFO` is a candidate replacement, unverified. Switching to the generic XWB or BMX sign-on instead would lose the CIA session id that lakeraven-ehr stores on audit rows (lakeraven-ehr#759), and would need another way to tie the two audit trails. Choose between the two.
- A written exceptions list is needed for what stays VueCentric: today the psych CPT and problem list, and any non-BH writes.
