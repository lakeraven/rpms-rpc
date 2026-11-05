# Behavioral Health save RPCs: what each reads and what it files

Read in the pinned build's routines (`rpms-ops/data/standup/bcer-9.0-ydb/r/AMHGSVF.m`, `AMHGEVF.m`) and the
broker inventory (`*-broker_8994.txt`, option `AMHGRPC`). Read only; no broker was run for this note.
The live write specs (ADR 0009) are what prove each wrapper; this note settles the two points #525 left unread.

## Settled point 1: does `MODV^AMHGEVF` link or create a PCC visit?

**No.** `MODV` (AMHGEVF.m:77-137) files one MHSS RECORD (`9002011`) through `UPDATE^DIE` (add) or `FILE^DIE` (edit),
plus the provider multiple (`9002011.02`, `MODPRV`) and an audit entry (`VAUD`). It sets no PCC visit pointer
and calls no visit API. The only visit-related text in `AMHGEVF` is `S APCDOVRR=1` (lines 10 and 23).
A BH record is therefore its own record; a PCC visit exists only if another path created one (scheduling check-in:
`CHECKIN^BSDX25` -> `GETVISIT^BSDAPI4`, when the clinic's create-visit flag is set). A wrapper must not claim a PCC
visit from a BH save, and `BehavioralHealth.save_visit` must not report one.

## Settled point 2: what each RPC accepts

All take one string `AMHSTR`, pipe-delimited (`P="|"`, repeating items separated by `~`, `R="~"`), and reply with a
two-row table: header `T00030Result` (VISIT replies `T00010BMXIEN`), then the new or edited record IEN, or an error
string `0~<reason>` set by the filer into `AMHER`. First two pieces are always `DM|REC`: data mode (`A` add, `E` edit)
and the MHSS RECORD IEN (blank on add).

| RPC | Tag | `AMHSTR` pieces (after `DM\|REC`) | Filer |
|---|---|---|---|
| `AMHG SAVE VISIT` | `VISIT^AMHGSVF` | 3 PP, 4 PRO, 5 CLN, 6 TOC, 7 ARR, 8 EDT, 9 LOC, 10 AW, 11 COM, 12 P (patient), 13 GN, 14 TIG, 15 ESIG, 16 ATG | `MODV^AMHGEVF` |
| `AMHG SAVE PROGRESS NOTES` | `PN^AMHGSVF` | 3 CC, 4 PN, 5 CMT, 6 PD, 7 PLN, 8 P | `CCPD`, `PN`, `CMT` in AMHGEVF |
| `AMHG SAVE SCREENING` | `SCREEN^AMHGSVF` | 3 A, 4 AC, 5 D, 6 DC, 7 IP, 8 IPC, 9 PP, 10 P, 11 APRV, 12 DPRV, 13 IPRV, 14 S, 15 SC, 16 SPRV, 17 SS, 18 SSC, 19 SSIP | `SCREEN^AMHGEVF` |
| `AMHG SAVE HEALTH FACTORS` | `HF^AMHGSVF` | 3 HF list (`~`-joined items, each `name~level~qty~comment`), 4 P | `MODHF`, `DELHF` |
| `AMHG SAVE MEASUREMENTS` | `MSR^AMHGSVF` | 3 MSR list (each `name~~value~provider`), 4 P | `MODMSR`, `DELMSR` |

Assessment is registered as `AMHG SAVE ASSESSMENT` -> `ASS^AMHGSINT` (not `AMHGSVF`), so it is a different routine
from the rest and is not wrapped here. Earlier notes saying "no RPC for ASS" were wrong about the registration.

On an empty `AMHSTR` the PN, SCREEN, HF and MSR tags rebuild it from `CATSTR^AMHGU`; the wrappers always send it.
Edits (`E`) with a blank `REC` are silently turned into adds by `MODV` (`I DM="E",REC="" S DM="A"`); the wrapper must refuse a blank record on edit.
A screening filed here must be matched with the screening store the clinic reads (health factors vs the screening fields);
PHQ-9 and GAD-7 totals ride on `AMHG SAVE SCREENING NEW` (`SCREENN^AMHGSVFA`), which is out of this issue's list.
