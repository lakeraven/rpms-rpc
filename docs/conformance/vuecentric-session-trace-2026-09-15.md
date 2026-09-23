# VueCentric session trace — observed RPC surface of one encounter

**Source:** VIM trace export, `ExportDate 15-Sep-26 00:39`
**Captured window:** `00:30:42.606` → `00:39:11.544` (8m 29s)
**Items:** 1000 (TraceSeq **616 → 1615**)
**Raw trace:** NOT committed — held out of git per finding S-1 below.
**Classification:** `data/rpc_tiers/observed/ehr-session-2026-09-15.tsv`
**Decision it supports:** `docs/adr/0004-frontend-agnostic-rpc-tiers.md`

> **Sanitized for commit.** The encrypted electronic-signature token observed in
> this session is redacted below (finding **S-1**) — the XWB cipher is reversible,
> so the captured value is credential material regardless of it being a demo
> account. The raw `TraceLogExport.xml` is deliberately **not** committed for the
> same reason. Everything else here is synthetic demo data (§0).

---

## 0. Data classification: synthetic, not PHI

Everything in the file is demo/test data. Nothing here is a partner name or real patient.

| Field | Value |
|---|---|
| Patient | `TESTPATIENT,ALICE` — DFN 100, MRN 90-01-00, DOB Jan 15 1980, F, age 46 |
| Address | `123 TEST STREET, COLORADO 12345` |
| User | `MANAGER,SYSTEM` — DUZ 4 |
| Facility / clinic | `DEMO HEALTH CENTER`, `DEMO PRIMARY CARE` (loc 6), `DEMO IHS CLINIC` |
| Provider DEA address | `123 ELM STREET, ANYWHERE, ILLINOIS 99999` |
| Visit IEN | 1019 (`3260915.003`, AMBULATORY) |

**Caveat:** one item is *not* safe to treat as inert — see finding **S-1**.

---

## 1. What the session did

A complete ambulatory primary-care encounter driven from the VueCentric EHR
shell: PCC data entry → reminder dialog → progress note → orders → sign.

| Time | Phase | Evidence |
|---|---|---|
| 00:30:42 | *(trace buffer already rolling)* — chart open, problem list IPL load | `BGOPROB1 EDPROB`, `BGOVPOV GET` |
| 00:30:46–00:31:29 | **Vitals grid** — typed, validated field-by-field (`BEHOVM VALIDATE` ×11) | `BEHOVM SAVE`: TMP 96 F, PU 90, RS 9, **BP 140/90**, O2 99%, Pain 9, HT 69 in, WT 155 lb → BMI 22.89 |
| 00:31:40–00:31:56 | **Chief complaint** | `BGOCC SET` → "1.) Evaluation and management of Moderate Cold for 10 Days." |
| 00:31:59–00:32:06 | **Exam** | `BGOVEXAM SET` 32 = EYE EXAM - GENERAL, NORMAL/NEGATIVE |
| 00:32:14 | **Health factor** | `BGOVHF SET` 54 = READ |
| 00:32:37 | **Patient education** | `BGOVPED SET` 3934 = ADV-INFORMATION, 3 min, Individual, level 2 |
| 00:33:04–00:33:13 | **Problem + POV** | `BGOPROB SET` / `BGOVPOV SET` → SNOMED 6142004 / **ICD-10 J11.1 Influenza**, Primary, Episodic |
| 00:33:20–00:33:41 | **Progress note created** | `TIU CREATE RECORD` (doc 13, title 248 PROGRESS NOTE), template boilerplate expanded (`TIU TEMPLATE GETBOIL` ×45) |
| 00:34:00–00:35:04 | **Reminder dialog** | `ORQQPXRM DIALOG PROMPTS` ×42 → `BEHOENPC SAVE`: patient ed TO-PREVENTION, HF **CEREMONIAL USE ONLY**, exam 33 **INTIMATE PARTNER VIOLENCE**, and measurements HT 69 / WT 155 / **BP 120/80** |
| 00:35:25 | Reminder text inserted into note | `ORQQPX REM INSERT AT CURSOR` |
| 00:35:43–00:36:25 | **Two medication orders** | `ORWDX SAVE` → order `10;1` Outside Med ASPIRIN TAB,SA; order `11;1` ASPIRIN TAB,SA 800MG, 1 tab PO daily, qty 7, 7 days, 0 refills |
| 00:36:25–00:36:40 | Third order `12;1` created then discontinued | `ORWDXA DC` → `DELETED: *UNSIGNED*` |
| 00:36:46–00:36:51 | Labs / consults browsed (both empty) | `ORWLRR NEWOLD`, `ORQQCN LIST` → "PATIENT DOES NOT HAVE ANY CONSULTS/REQUESTS ON FILE" |
| 00:36:58–00:38:22 | **CPT / E&M coding** | `BGOVCPT CPTLKUP` ×5 incl. **G2211** |
| 00:38:40–00:38:45 | **Time / complexity** | `BGOVTM SET` 2 → 20 min, factor 15 |
| 00:38:52–00:39:04 | **Sign** | `ORWU VALIDSIG` → 1 · `TIU SIGN RECORD` doc 13 → 0 · `ORWDX SEND` orders `10;1`,`11;1` → `RS` (released/signed) |
| 00:39:04–00:39:11 | Alert cleanup, ESIG queue drained, visit refresh | `ORWORB KILL …`, `ESIG.DELETE` ×7 |

---

## 2. Findings

### S-1 — The electronic signature code is captured in the trace export (security)

`ORWU VALIDSIG` (seq 1496) is traced with its parameter in the clear:

```
RPC: ORWU VALIDSIG
  #1 : <REDACTED — encrypted e-sig, recoverable>
  Results: 1
```

The same token is reused in `TIU SIGN RECORD` (#2) and `ORWDX SEND` (#4). That
value is the user's verify/e-sig code under the XWB broker cipher — a fixed,
publicly-documented substitution table, i.e. trivially reversible. Anyone who
obtains a trace export obtains a working signature code for that user.

Benign here (`MANAGER,SYSTEM` on a demo box). On a production RPMS site, a
clinician who clicks "export trace log" to send to a help desk is emailing their
e-sig. **Recommendation:** treat `*.xml` trace exports as credential material;
redact params for `ORWU VALIDSIG`, `TIU SIGN RECORD`, `ORWDX SEND`, `XUS AV CODE`
before sharing. Worth a redaction pass in `RpmsRpc::PhiSanitizer` for our own
trace tooling, and a note in the ops runbook.

### B-1 — `DDR GETS ENTRY DATA` returns `[ERROR]`

```
seq 1237  #1: ("FIELDS")=4  ("FILE")=100  ("FLAGS")=IE  ("IENS")=0,
          Results: [ERROR]
```

`IENS` is `0,` — an empty/zero IEN against file 100 (ORDER). The caller asks for
field .4 and gets a bare `[ERROR]` with no diagnostic. We wrap this RPC
(`lib/rpms_rpc/api/ddr_fileman.rb`), so the malformed-IENS case is a conformance
test we should have.

### B-2 — ICD-10 problems reported as "Invalid Code (not found in the ICD-9-CM system)"

```
seq 815  BEHOPLCV LIST →
  11^A^Type 2 diabetes mellitus ^Invalid Code (not found in the ICD-9-CM system)^…^44054006
  10^E^Hearing test abnormal   ^Invalid Code (not found in the ICD-9-CM system)^…^313203003
```

The coded-problem-list view resolves against ICD-9 while everything else in the
session (`ORWDXIHS CLININD`, `BGOVPOV SET`) is ICD-10 (`E11.9`, `R94.120`,
`J11.1`). Either the environment's ICD-9 lexicon is unpopulated, or `BEHOPLCV`
hardcodes the ICD-9 coding system. Confirm against the routine before assuming
it's environmental.

### B-3 — ICE outage text was written into the signed note

```
("TEXT","21","0")=Immunizations Due: No response from ICE. Check Tomcat/ICE installation. #127
```

The Immunization Calculation Engine is down on this box, and the TIU object
substituted its error string into the note body — which was then signed
(`TIU SIGN RECORD` → 0). Two problems: the environment defect, and the fact that
a failed object expansion silently becomes permanent clinical text rather than
blocking the signature.

### B-4 — Duplicate, conflicting vitals for one visit

`BEHOVM SAVE` (00:31:28) wrote **BP 140/90**, HT 69, WT 155. The reminder-dialog
`BEHOENPC SAVE` (00:35:04) wrote a *second* HT 69 / WT 155 / **BP 120/80** to the
same visit. `BGOTRG GETSUM` thereafter renders both stacked:

```
BP: 140/90 mmHg
…
HT: 69 in
WT: 155 lb
BP: 120/80 mmHg
```

Two BPs on one encounter with no disambiguation in the triage summary. Whichever
one a downstream consumer (CRS/GPRA numerator, FHIR Observation export) picks
first changes the answer. Relevant to **rook** measure extraction — worth a
BDD scenario.

### B-5 — Note content is stale relative to the orders it was signed with

The note text sent at sign time (seq 1506, 00:38:52) still reads:

```
Visit Orders:
    No Orders.
```

…but `ORWDX SEND` released two aspirin orders eight seconds later, and
`BGOTRG GETSUM` at 00:38:45 already listed both. TIU objects expand once at
insert; re-signing does not re-expand. Expected VistA/CPRS behaviour, but it
means the signed note under-documents the encounter. Flag as a known divergence
target for our note-generation path — we should re-expand at sign.

`HPI:` was also left empty.

### B-6 — `BGOVCPT CPTLKUP` returns nothing for **G2211**

```
seq 1449/1452  #1 : G2211^1^9/15/2026…  Results: (empty)
```

G2211 is the E&M visit-complexity add-on — directly relevant to primary-care
billing. Empty lookups at 00:37:37 and 00:37:40 (blank search term) also return
nothing. Either the CPT table predates G2211 or the lookup flags are wrong.
Check the CPT file version on this environment before treating it as a code bug.

### P-1 — `ORWDX DGNM` is called 64 times for 11 distinct answers

64 calls between 00:35:43 and 00:36:50 (order entry), only **11 distinct
param/result pairs** (`UD RX` → 21, etc.). It's a pure name→IEN lookup. 53 of 64
round-trips are redundant. Same shape, smaller: `CIAVMRPC GETPAR` ×16,
`BGOUTL GETPARM` ×16, `BEHOUSCX HASKEYS` ×15, `BGOTRG GETSUM` ×19 (the triage
summary is re-fetched on *every* PCC component change).

Overall: **727 RPCs for one 8-minute encounter.** A session-scoped cache for
parameter/lookup RPCs is the single biggest latency win available in a
replacement client.

### O-1 — The trace is a ring buffer; the first 615 events are gone

`TraceSeq` starts at **616**. Signon, `XUS AV CODE`, context creation, patient
select and initial chart load all happened before the window. If we want a
complete capture, the trace has to be armed *before* signon, or the buffer size
raised.

---

## 3. Coverage against `rpms-rpc`

| | |
|---|---|
| Distinct RPCs observed | **223** |
| Total calls | 727 |
| Already wrapped in `rpms-rpc` | **30 (13%)** |
| Not wrapped | **193** |

Wrapped: `BEHOVM SAVE/TEMPLATE/VALIDATE`, `BGOPROB SET`, `BGOPROB GET CLASS`,
`BGOTRG GETSUM`, `BGOVEXAM SET`, `BGOVHF SET`, `BGOVPOV SET`, `CIANBRPC CANRUN`,
`CIAVMRPC GETPAR`, `DDR GETS ENTRY DATA`, `ORWOR UNSIGN`, `ORWORR AGET`,
`ORWPT SELECT`, `ORWPT INPLOC`, `ORWU VALIDSIG`, and 15 `TIU *`.

Largest unwrapped clusters:

| Count | Namespace | Domain |
|---|---|---|
| 19 | `TIU *` | note lifecycle beyond create/sign |
| 12 | `ORWDPS*` | pharmacy order dialog |
| 11 | `ORWDX*` | generic order dialog |
| 8 | `ORQQCN*` | consults |
| 7 | `BGOUTL*` | VueCentric utility/parameters |
| 6 each | `BGOPROB*`, `BGOVPED*`, `ORWPCE*` | problem, patient ed, PCE |
| 5 each | `BGOVPOV*`, `ORQQPXRM*` | POV, reminders |
| 4 each | `BEHORXF*`, `ORWD*`, `ORWDXA/C/M*`, `ORWORB*`, `ORWU*` | eRx, order actions, alerts |

Full per-RPC classification: `data/rpc_tiers/observed/ehr-session-2026-09-15.tsv`.

### Why this matters for the pillar allowlists

`docs/RPC_COVERAGE.md` derives its capture note from the allowlists themselves;
it currently reports VueCentric BDMG, BSDX, BDW, BHL and BWH as still
placeholders, and carries no entry at all for the EHR pillar. This trace **is** a
capture: 223 empirically-observed RPCs for the EHR pillar's core clinical workflow, with
real parameter shapes and return formats. That is materially better evidence than
probing an option's RPC list, because it tells us call *order* and *payload*, not
just membership.

Suggested next step: land the 223-name list as `data/pillar_allowlists/ehr.txt`
plus a trace-derived fixture set, and add a `bin/` importer that converts a
`VIMTraceLog` export into fingerprint/allowlist entries. Because the demo data is
synthetic, the trace itself is safe to commit as a fixture — **after** stripping
the e-sig token per S-1.

---

## 4. Recommended follow-ups

1. **S-1 redaction** — sanitize signature params in trace tooling + ops runbook note. (security, do first)
2. **Import the 223 RPCs** as the EHR-pillar allowlist; write the `VIMTraceLog` → allowlist/fingerprint importer.
3. **Commit a sanitized copy of this trace** as a conformance fixture; pin parameter shapes for the 30 already-wrapped RPCs against it.
4. **B-4 (duplicate vitals)** — BDD scenario in `rook` for "one visit, two BPs".
5. **B-1** — malformed-IENS conformance test for `DDR GETS ENTRY DATA`.
6. **P-1** — session-scoped lookup cache in the client; `ORWDX DGNM`/`GETPARM`/`GETPAR`/`HASKEYS` are all cacheable.
7. **Re-capture with the buffer armed before signon** to recover seq 1–615 (auth + chart-open sequence).
8. **Environment tickets** (not code): ICE/Tomcat down (B-3), ICD-9 lexicon (B-2), CPT table missing G2211 (B-6).
