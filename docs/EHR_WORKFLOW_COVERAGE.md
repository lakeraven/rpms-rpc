# EHR-pillar RPC coverage — evidence and method

How the EHR-pillar allowlists were captured, and what a frontend-agnostic client
must call versus what exists only to drive a fat GUI. Companion to the generated
`RPC_COVERAGE.md`; this file holds the reasoning, that file holds the numbers.

## Method

Two independent sources, cross-referenced:

1. **A live workflow trace.** A complete ambulatory primary-care encounter driven
   from the VueCentric shell (chart open → PCC data entry → reminder dialog →
   progress note → orders → sign) was captured from the broker: **727 RPC calls,
   223 distinct RPCs, 8 minutes.** All data synthetic. A trace is stronger evidence
   than probing an option's RPC multiple, because it carries call *order* and
   *payload shape*, not just membership.
2. **A modern frontend-agnostic RPMS client's exercised RPC set** (**218 distinct
   RPCs**), used to distinguish RPCs a headless client genuinely needs from the
   GUI plumbing it discards, and to reach surfaces the primary-care trace never
   exercised (behavioral health, registration).

Each observed RPC is classified on two axes:

- **coupling** — where it originates: `vuecentric-framework` / `vuecentric-component`
  (the VueCentric shell), `cprs-dialog-machine` / `tiu-editor` / `cprs-chrome`
  (the CPRS fat client), or unmarked (a real data operation).
- **disposition** — what a modern client does with it: **canonical** (keep, re-
  implement on our API), **legacy** (discard — GUI plumbing), **quarantine**.

## What a modern client discards

Roughly a third of the primary-care traffic exists only to drive the fat client:

| Shed set | RPCs | Calls | What it is |
| --- | --- | --- | --- |
| VueCentric shell | 18 | ~98 | param store, triage-summary re-render, picker category lists, security probes |
| CPRS order-dialog machine | 24 | 151 | the order/reminder dialog state machine (`ORWDX*`, `ORWDPS*`, `ORQQPXRM`) |
| CPRS template editor | 9 | 91 | TIU boilerplate/template expansion |
| CPRS window chrome | 13 | 30 | graph views, window geometry, unit lookups |

A frontend-agnostic client renders its own dialogs, templates, and layout, and
keeps its own parameter/UI state — so it calls none of these. The exception a
BPRM-derived client keeps is the two **CIA-broker** RPCs (`CIANBRPC CANRUN`,
`CIAVMRPC GETPAR`) — broker plumbing, not GUI — and the CPRS **order-dialog**
subset if it reimplements ordering rather than modelling orders natively.

## Coverage

Raw coverage against the primary-care trace understates, because it counts the
shed plumbing we deliberately never wrap. Split by disposition:

| Disposition | Observed | Wrapped | Coverage |
| --- | --- | --- | --- |
| canonical (keep) | 161 | 25 | 16% |
| legacy (discard) | 56 | 5 | 9% |
| quarantine (discard) | 6 | 0 | 0% |

The near-zero coverage of the discard piles is the plan working. The number that
matters is **16% of the canonical set for this one workflow**, leaving ~136
canonical RPCs as the primary-care EHR backlog.

**But primary care is not the pilot.** The trace never exercised behavioral
health. Against the **AMHG behavioral-health pillar** — the December surface —
coverage is **40 / 71 = 56.3%** (see `data/pillar_allowlists/amhg.txt`). The BH
call surface was recovered from the modern client's exercised set: intake,
screening, treatment plans, suicide-risk forms, DSM axes, progress notes, group
visits, case management. That is the empirical BH reference the VueCentric
primary-care trace could not provide.

## Backlog, in priority order

- **AMHG behavioral health — 31 unwrapped of 71** (the December gap). The GET
  treatment-plan, screening and suicide RPCs are already among the 40 wrapped;
  what is missing is the write path plus a set of read/display surfaces. The
  full 31, by kind:

  | Kind | Count | RPCs |
  | --- | --- | --- |
  | **Writes (highest priority)** | 21 | `AMHG SAVE ACTIVITY`, `AMHG SAVE ADMINISTRATIVE ACTIVITY`, `AMHG SAVE ASSESSMENT`, `AMHG SAVE CASE MANAGEMENT`, `AMHG SAVE COMMUNITY ACTIVITY`, `AMHG SAVE GROUP DATA`, `AMHG SAVE GROUP IND PNCA`, `AMHG SAVE MH RECS TO GROUP`, `AMHG SAVE POV`, `AMHG SAVE PROGRESS NOTES`, `AMHG SAVE SCREENING`, `AMHG SAVE SUIC CONT FACTORS`, `AMHG SAVE SUICIDE FORM`, `AMHG SAVE SUICIDE METHOD`, `AMHG SAVE SUICIDE NARRATIVE`, `AMHG SAVE SUICIDE SUBSTANCES`, `AMHG SAVE TREATMENT PLAN`, `AMHG SAVE TREATMENT REVIEW`, `AMHG SAVE VISIT`, `AMHG CREATE TREATMENT PLAN`, `AMHG INTAKE DELETE` |
  | Reads / display | 7 | `AMHG GET BROWSE VISITS`, `AMHG GET FACE SHEET`, `AMHG GET HEALTH SUMMARY`, `AMHG GET INTAKE DISPLAY`, `AMHG GET TABLE`, `AMHG GET VISITS ALL PATS`, `AMHG LIST ENCOUNTERS` |
  | Print | 3 | `AMHG PRINT ENCOUNTER FORM`, `AMHG PRINT SUICIDE FORM`, `AMHG PRINT TREATMENT PLAN` |

  The writes are the pilot-blocking subset: a clinician can read a treatment
  plan today but cannot save one. The read/display and print RPCs are real gaps
  but degrade the surface rather than block the workflow.
- **AGG registration** — a further ~36 RPCs the modern client exercises that the
  primary-care trace did not.
- Primary-care canonical backlog (~136) — deferred behind the BH pilot.

## Reproducing

Populate `data/pillar_allowlists/<pillar>.txt` (one RPC per line), then
`ruby bin/build_coverage_matrix` (or `rake coverage:matrix`) to refresh
`RPC_COVERAGE.md`. Workflow traces are treated as credential material until the
e-signature parameters are stripped (`ORWU VALIDSIG`, `TIU SIGN RECORD`,
`ORWDX SEND`, `XUS AV CODE`) and are not committed.
