# ADR 0004: Frontend-agnostic RPC tiers — MVC, and a legacy set kept separate

**Status:** Proposed
**Date:** 2026-09-15
**Extends:** [ADR 0001 — Scope and no Rails coupling](0001-scope-and-no-rails-coupling.md)

## Context

A VueCentric session trace (one complete ambulatory encounter, 8m29s, **727 RPC
calls across 223 distinct RPCs**) gave us the first empirical picture of what the
legacy EHR client actually talks to. Classifying it revealed a problem that
coverage counting hides.

Not all 223 RPCs are the same *kind* of thing:

- Some carry **domain state** — the problem, the POV, the visit, the note text,
  the order.
- Some enforce **domain invariants** — locking, signature, authorization.
- Some exist **only to drive a Windows widget** — window geometry, column
  widths, graph-pane preferences, site-configured pick lists, server-rendered
  display strings.
- Some implement a **stateful remote-UI protocol** — the CPRS order dialog,
  where the server drives the client's form field by field and the client echoes
  dialog state back (`ORDIALOG("WP",…)`).

`docs/RPC_COVERAGE.md` counts all four identically. Under that metric, wrapping
`ORWCH SAVESIZ` (persist the user's window size) scores the same as wrapping
`BGOVPOV SET` (record the purpose of visit). They are not the same, and treating
them the same has a specific failure mode: **we re-implement CPRS.** Every RPC in
the dialog-machine tier that we faithfully wrap pulls the shape of the 1997
Delphi client into our stack, and a client written against those wrappers is a
CPRS clone with a new skin.

The constraint is that **our stack should be frontend-agnostic**. rpms-rpc is a
gem; lakeraven-ehr is one consumer, but not the only possible one, and no
consumer should inherit VueCentric's widget model as the price of talking to
RPMS.

Two pieces of evidence make this concrete:

- **The trace itself.** 49% of the wire traffic (354 of 727 calls) is
  presentation or dialog protocol carrying no domain value.
- **An independent RPMS derivative.** A separate modernization effort serving a
  non-tribal program used **zero** `BGO*` and **zero** `BEHO*` across its 343 routines,
  while reading and writing PCC `^AUPNVSIT` and its V-files directly, and
  depending on IHS `BSD*` scheduling and `ABM*` billing. It replaced the
  component layer and kept the substrate. That is the seam, found twice
  independently.

## Decision

### 1. Every RPC is assigned an MVC tier

| Tier | Meaning | Count | Calls |
|---|---|---:|---:|
| **M** — model | Durable clinical/business state and its reads | 107 | 247 |
| **C** — controller (domain) | Locking, signature, authorization, validation | 60 | 126 |
| **C-dialog** — controller (protocol) | CPRS order-dialog state machine | 24 | 151 |
| **V** — view | Presentation state, pick lists, rendered strings | 32 | 203 |

The tier is a property of the RPC's **contract**, not its package or its
namespace. `BGOVPOV SET` is Model even though `BGO*` is the VueCentric component
package; `TIU TEMPLATE GETBOIL` is View even though `TIU` is otherwise Model.
Classifying per-package would be wrong in both directions.

### 2. Three dispositions, and the legacy set is kept physically separate

| Disposition | Rule | Count | Calls |
|---|---|---:|---:|
| **canonical** | Frontend-agnostic. Wrap and expose. | 161 | 363 |
| **quarantine** | Writes real state; payload is dialog state. Adapter only. | 6 | 10 |
| **legacy** | Presumes a legacy client. Never enters the canonical stack. | 56 | 354 |

These live as first-class sets in `data/rpc_tiers/{canonical,quarantine,legacy}.txt`.

**The legacy set is not a denylist of things we haven't got to yet — it is a set
we have decided not to have.** An RPC appearing there is a design conclusion.
Adding a wrapper for one is a design error, not a coverage gain, and
`RPC_COVERAGE.md` must exclude the legacy set from its denominator so that
"unwrapped" never reads as "todo".

### 3. The frontend-agnostic test is mechanical

An RPC is **not** canonical if any of the following is true. These are the
disqualifiers, in order of how often they fire in the trace:

1. **It returns a pre-rendered display string** meant to be shown as-is.
   `BGOTRG GETSUM` returns `"BP: 140/90 mmHg\nBMI: 22.89"`; `ORWORR GETTXT`
   returns the order as the client prints it; `BEHORXFN VITALFMT` formats
   vitals. A canonical API returns the measurement, the unit and the timestamp,
   and lets the consumer render.
2. **It reads or writes client session/widget state.** `ORWCH LOADSIZ`/`SAVESIZ`
   (window geometry), `ORWRP3 EXPAND COLUMNS`, `ORWGRPC GETPREF`,
   `CIAVMRPC GETPAR`/`SETVAR` (VueCentric object registry), `BGOUTL GETPARM`/
   `SETPARM`.
3. **It requires the caller to hold a server-side dialog session**, or to echo
   dialog state back. The whole `ORWDX*`/`ORWDXM*`/`ORWDPS*` selection protocol,
   and the reminder-dialog prompt machine.
4. **It returns a site-configured pick list whose only purpose is to populate a
   picker** — `BGOCPTPR GETCATS`/`GETITEMS`, `BGOSNOPR GETITEMS`. The underlying
   *codes* are canonical; the site's menu arrangement of them is not.

Note what is deliberately **not** a disqualifier: being IHS-authored, or living
in a VueCentric package. Provenance is orthogonal to tier — `BGOVHF SET` writes
a real health factor and is canonical; `BGOUTL GETPARM` fetches a widget
parameter and is legacy. Both are `BGO*`.

### 4. Quarantine, for the cases with no canonical path

Six RPCs write genuine clinical state but accept only CPRS dialog payloads:
`ORWDX SAVE`, `ORWDX SEND`, `ORWDXA DC`, `ORWDXC SESSION`, `ORWDXC SAVECHK`,
`ORWDXC ACCEPT`. Ordering has no other server-side entry point, so a blanket ban
would mean no order entry at all.

They are permitted **behind a narrow adapter that constructs the dialog payload
internally**, from a domain-shaped argument. The adapter's dialog knowledge does
not leak: no consumer ever sees an `ORDIALOG` reference, a dialog IEN, or a
form ID. The quarantine set is expected to shrink — each member is a candidate
for replacement by a direct FileMan/DDR path, which is the route that
independent derivative took.

### 5. Replacement, not re-implementation, for the view tier

We do not port the view tier to a web client. Window geometry, column widths and
graph preferences are the new client's own concern, stored in the new client's
own store. Pick lists become L2/L3 configuration data captured by the
configure-then-capture-delta method, not RPC round-trips. Rendered strings become
rendering, on whichever side owns presentation.

This is why the view tier being 203 calls (28% of traffic) is good news rather
than bad: it is 203 calls a frontend-agnostic client never makes.

## Consequences

**Coverage numbers change, and get more honest.** The denominator drops from 223
to 167 (canonical + quarantine) for this trace. Wrapped-RPC counts that included
view-tier calls should be re-stated.

**Some already-wrapped RPCs may be in the legacy set.** The gate (below) will
surface them. Each is a decision: deprecate the wrapper, or justify it in the
tier file with a reason. Neither is automatic.

**Tiering is judgement, and some calls are genuinely arguable.**
`ORQQPXRM DIALOG PROMPTS` is classified dialog-machine, but clinical reminders
carry real decision-support content; a future consumer may want the reminder
*definitions* without the prompt protocol. That would be a new canonical path,
not a reclassification of this RPC. Arguable cases are recorded in the TSV with
their tier, so disagreement is visible rather than silent.

**One trace is one sample.** 223 RPCs from one encounter is not the full pillar.
The tiers must be regenerated as more traces land, and the counts here are
pinned to `reference/traces/TraceLogExport.xml` (15-Sep-2026). A second trace
that adds RPCs does not invalidate the rule; it extends the sets.

**The gate can be wrong in the safe direction.** It fails the build when a
mapping names an RPC in the legacy set. It cannot detect a *canonical* wrapper
that leaks presentation — that stays a review question, which is what item 3
exists to make answerable.

## References

- [ADR 0001 — Scope and no Rails coupling](0001-scope-and-no-rails-coupling.md) — the same instinct applied to the web framework
- `data/rpc_tiers/{canonical,quarantine,legacy}.txt` — the sets
- `data/rpc_tiers/rules.yml` — the curated judgement, separate from the code applying it
- `bin/trace_classify` — regenerates the sets from a trace export
- `docs/conformance/vuecentric-session-trace-2026-09-15.md` — the session this was derived from, sanitized
- `data/rpc_tiers/observed/ehr-session-2026-09-15.tsv` — full per-RPC classification with call counts

**Not committed, by decision.** The raw `TraceLogExport.xml` is held out of git:
a VIM trace captures the electronic-signature token as sent, and the XWB cipher
is reversible, so an export is credential material (finding S-1 in the
conformance doc). Traces stay under an out-of-repo path; only sanitized
derivatives land here. `bin/trace_classify` therefore takes a trace by path and
is not wired to a committed fixture.

The independent corroboration for the same seam — an RPMS derivative serving a
non-tribal program that used zero `BGO*`/`BEHO*` while reading and writing PCC
`^AUPNVSIT` directly — is an external checkout, not vendored here. Its findings
are summarized in the Context section above rather than cited by path.
