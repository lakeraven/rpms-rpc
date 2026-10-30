# Leaving VueCentric-only RPCs: what the December path needs

**Status:** findings and a work list, 2026-10-30. Nothing here is built. Read-only analysis of the pinned build `bcer-9.0-20261012-e7923a4-ydb`.
**Why:** rpms-rpc signs on as the VueCentric application (`CIAV VUECENTRIC`) and calls 33 RPCs that sit in no other broker option. The direction is stock RPMS RPCs first, then DDR FILER for FileMan-only changes, otherwise "not supported, done in RPMS". We write no M.

## How the 33 were counted

`lib/rpms_rpc/required_rpcs.json` lists 191 distinct RPCs across 45 modules. Joined against the build's broker-option inventory (`data/inventories/<build>/…-contexts_19_05.txt`):

- 33 RPCs are in `CIAV VUECENTRIC` and no other option.
- 157 are also in another option.
- 1 is in no option (`CIANBRPC CANRUN`, the CIA sign-on RPC).

The build has 52 broker options. `CIAV VUECENTRIC` holds 1,639 RPCs and `OR CPRS GUI CHART` 1,013. The IHS package options each carry their own list (`BSDXRPC` 69, `AGGRPC` 101, `AMHGRPC` 223, `BMXRPC` 59).

## Class key

- **A** a stock equivalent exists with equivalent behaviour.
- **B** a stock equivalent exists but loses something IHS-specific.
- **C** DDR on named file and fields could do it. FileMan-only is a risk if it bypasses business rules.
- **D** not supported outside VueCentric.
- **E** cannot tell yet.

## The December path

Two routes the first pass missed:

- **Scheduling check-in creates the PCC visit.** `CHECKIN^BSDX25` (RPC `BSDX CHECKIN APPOINTMENT`, option `BSDXRPC`) calls `GETVISIT^BSDAPI4`, and again with `FORCE ADD` when no visit exists, then adds the provider (BSDX25.m lines 132-150). It does so only when the clinic's hospital-location record has its create-visit flag set (file 9009017.2, field .09).
- **The IHS Behavioral Health package saves visits itself.** `AMHG SAVE VISIT` (`VISIT^AMHGSVF`, option `AMHGRPC`) writes the BH record through `MODV^AMHGEVF`. The same routine has `POV`, `PN`, `SCREEN`, `HF`, `MSR` and `ASS` entry points. rpms-rpc wraps the BH reads only.

| Need | VueCentric-only RPC used today | Non-VueCentric route | Class | Notes |
|---|---|---|---|---|
| Signed-on user (DUZ) | `CIAVCXUS VIMINFO` | `XUS AV CODE` (DUZ in RET(0)), `XUS GET USER INFO` (option `XUS SIGNON`) | A | Needs the generic XWB or BMX sign-on instead of CIA. Loses the CIA session id (see open points). |
| Security keys | `CIAVCXUS HASKEYS` | `ORWU NPHASKEY` (one call per key), or DDR LISTER on 200.051 | A | Always pass the signed-on DUZ. `ORWU HAS KEY` is not registered in this build. |
| Division and station | `BEHOSICX SITEINFO` | `XUS GET USER INFO` line 3, `XUS DIVISION GET/SET` | A | `XUS DIVISION SET` checks the user's division multiple; `CIANBRPC DIVSET` does not. Address and name by DDR read of file 4. |
| Widget registry | `CIAVMCFG GETREG` | none needed | D | Dumps VueCentric's widget registry. The web app has no use for it. |
| Banner flags (C, W, A, D) | `BEHOCACV CWAD` | `ORWPT CWAD` (option `OR CPRS GUI CHART`) | A | Same scan; no Patient Record Flag letter "F". |
| Patient Record Flags | `BEHOCACV CWAD` ("F") | none known | E | A behavioral-health safety flag is a real banner item. `ORPRF*` RPCs unchecked. |
| Designated provider | `BEHOPTPC GETBDP` | DDR read of patient file field .14; `ORWPT1 PRCARE` reads PCMM, which IHS sites do not fill | B | Latent bug: the banner uses the first row of an alphabetical category list. |
| Create the visit | `BEHOENCX FETCH` (create) | Scheduling check-in; `AMHG SAVE VISIT` for BH | A | Depends on the clinic's create-visit flag. Unverified on a running image. |
| Visit diagnosis | `BGOVPOV SET` | `AMHG SAVE POV` for BH visits | A for BH, E otherwise | Stock `ORWPCE SAVE` is registered to `CIAVCXPC`, a routine absent from the source tree. |
| Progress notes | (TIU, stock) | `AMHG SAVE PN` for BH notes | stock | |
| Screening results | `BGOVHF SET` | `AMHG SAVE SCREEN` | A (probable) | Which store a PHQ-9 or GAD-7 belongs in is unconfirmed. |
| Problem list | `BGOPROB SET/DEL` | `ORQQPL ADD SAVE`, `ORQQPL DELETE` | B | Loses SNOMED, laterality, IHS numbering. Needs a decision. |
| Psych CPT | `BGOVCPT SET` | none found | E | `Procedure.add` is wire-incompatible with `BGOVCPT SET`. |
| Vitals and measurements | `BEHOVM*`, `BGOVMSR*` | `AMHG SAVE MSR` (BH); GMV vitals unchecked | E | Not on the December path. |
| Immunization, refusal, eligibility, PHR | `BGOVIMM*`, `BGOREF*`, `BGOVIMM2 GETELIG`, `BEHOCCD*`, `BEHOCIR*` | none | D or E | Primary care, planned for later. The C-CDA is built in Rails, not from these RPCs. |

## Verified, and not

Read in the pinned routines (`rpms-ops/data/standup/bcer-9.0-ydb/r/`), not run:
`OPTCHK^CIANBUTL`; `CHECKIN^BSDX25` and `GETVISIT^BSDAPI4` call; `VISIT^AMHGSVF`; the `BGOVCPT` input layout (`Visit IEN ^ CPT IEN ^ DFN ^ Event date ^ Qty ^ Dx ^ Mod1 ^ Prov …`); `GETBDP^BEHOPTPC` and `ALLDP^BDPAPI`.

Not verified: any live behaviour (no broker was reachable); that `AMHGEVF` links the BH record to a PCC visit; the clinic create-visit flag on the target tenant; what the `AMHG SAVE POV/SCREEN/MSR` RPCs accept; whether `CIAVCXPC` exists on the running image; the generic-path RPCs under a non-CIA context.

## Open points

- Leaving CIA loses the CIA session id that lakeraven-ehr now stores on audit rows (lakeraven-ehr#759). The generic path needs another way to tie the two audit trails.
- A written exceptions list is needed for what stays VueCentric: today the psych CPT and problem list, and any non-BH writes.
- engage-health (public reference) routes each RPC to a package option, signs on over the BMX line, and ships its own M. We do not copy the M.
