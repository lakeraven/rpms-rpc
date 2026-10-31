# Registration and scheduling writes (rpms-rpc#418)

Evidence is from the pinned bcer YDB build: a tag-level reverse call graph over the routines in `/data/r` (external `TAG^RTN` refs, local tag refs, and fall-through, depth 6), intersected with every `#8994` `TAG^ROUTINE`. Indirection (`@X`, `XECUTE`) was not followed. `#8994` was read from `^XWB(8994)`.

Resolution 1 is a stock RPC that already reaches the M tag. Resolution 2 is DDR FILER or DDR LISTER, because no `#8994` entry reaches the tag and the FileMan write or read is the whole of what the tag does to those fields. Resolution 3 is not supported: the gem method sends no RPC, because a FileMan write would not be what the M routine does.

| Procedure | Resolution | Routine and tag | #8994 entry | rpms-rpc method |
| --- | --- | --- | --- | --- |
| Sex | 3 Not supported | `SEXELIG^AGUTL` (`AGUTL.m:51`); `AG2A.m:58-64` also clears `#9000001` `.23` | None. Callers are `AG2A` (roll-and-scroll edit) and `AG71A11` (KIDS post-install) only. `AGG UPDATE PATIENT` (`UPD^AGGPTUPD`) files `#2` `.02` and never reaches `SEXELIG` | `Registration.set_sex` |
| Gender identity | 2 DDR FILER | `SETGI^AUPNSOGI` to `SETGI`/`S9394^AUPNSOG3`: `UPDATE^DIE` on `9000001.9401` (`.01` DATE dinum, `2` OTHER) and `9000001.94011` (`.01` pointer to `9999999.104`) | None. `SETGI` reached 9 tags and no `#8994` entry | `Registration.set_gender_identity` |
| Sexual orientation | 2 DDR FILER | `SETSO^AUPNSOGI` to `AUPNSOG3`: `9000001.9301` / `9000001.93011` (pointer to `9999999.103`) | None | `Registration.set_sexual_orientation` |
| Legal sex | 2 DDR FILER | `SETLSEX^AUPNSOGI` to `AUPNSOG3:53`: `UPDATE^DIE` on `9000001.9201` (`.01` EFFECTIVE DATE dinum, `1` LEGAL SEX, `2` SOURCE pointer to `9000030`, `3` DATE ENTERED) | None | `Registration.set_legal_sex` |
| MBI write | 2 DDR FILER | `ADDMBI^AUPNMBI` (`AUPNMBI.m:6`): `UPDATE^DIE` on `9000001.44` (`.01` EFFECTIVE DATE dinum, `1` MBI uppercased, `2` SOURCE, `3` DATE ENTERED, `4` ENTERED BY = `DUZ`) | None | `Registration.add_mbi` |
| MBI read | 2 DDR LISTER | `GETMBI`/`HISTMBI^AUPNMBI` | `GETMBI` is reached only by lab-manifest RPCs (`BLR MANIFEST BUILD` and the others) incidentally. No RPC returns the MBI | `Registration.mbis` |
| Insurance billing order | 3 Not supported | `^AUPNICP` (`#9000035`), written by `LOADICP`/`DELICP^AGCAT` and `REVERSE^AGED4A2` (`DIC`/`DIK` with sequencing). BPRM adds raw SQL, which is not an RPC | None | `Registration.set_insurance_billing_order` |
| Insurance in use | 3 Not supported | `USED^AGUTILS` (scans 3PB bills and claims) | Only an internal guard inside `AGG UPDATE MEDICAID`. No RPC returns it | `Registration.insurance_in_use` |
| Undo check-in | 1 Stock RPC | `CANCHKIN^BSDX25` (`BSDX25.m:154`), reached from `CHECKIN^BSDX25` when the check-in time is `"@"` (`BSDX25.m:15`, `41`, `59-61`). Clears `9002018.4` `.03` and `#44.003` field `309` between `BEFORE`/`AFTER^SDAMEVT` | `BSDX CHECKIN APPOINTMENT` (`CHECKIN^BSDX25`) | `Scheduling.undo_checkin` |
| Holidays add/remove | 2 DDR FILER | HOLIDAY `#40.5` (`.01` DATE, `2` NAME; the only xref is `B`). The only writer is interactive `GO^SDHOL` (`DIC`/`DIE`) | None | `SchedulingSetup.add_holiday`, `SchedulingSetup.remove_holiday` |

DDR calls bind `CIAV VUECENTRIC` for the call and restore the caller's option. `Scheduling.undo_checkin` binds `BSDXRPC`, the option that registers `BSDX CHECKIN APPOINTMENT`.

## What DDR FILER skips

`DDR FILER` is `FILEC^DDR3` (`DDR3.m:14-18`). Mode `ADD` is `UPDATE^DIE`. Any other mode, including the `EDIT` that deletes a holiday by setting `.01` to `"@"`, is `FILE^DIE`. Both run with no `"E"` flag (`DDR3.m:15,18`), so the value is filed internal. The RPC does not translate an external code, apply a default the M tag would have stuffed, prompt the way an interactive `DIC`/`DIE` does, or update a file the tag updates in its own code.

FileMan triggers and MUMPS cross-references on the fields that are filed still run, because the write is FileMan. That is why the SOGI xrefs and the MBI field triggers do not have to be called by name.

The client supplies the values those tags would have put in the FDA, and nothing else:

- **Gender identity.** `values` are internal IENs in `#9999999.104`, not labels. `other` is filed as `#9000001.9401` field `2` only when it is non-blank text. An omitted `date` is the client's today; `FILEC^DDR3` would not default it. `AGI1`/`AGI2` (`AUPNSOGX`) fire on the write. Any code translation or other default inside `SETGI^AUPNSOGI` does not run.
- **Sexual orientation.** Same shape on `#9000001.9301` / `#9000001.93011`, with values as internal IENs in `#9999999.103`. `ASO1`/`ASO2` fire. `SETSO^AUPNSOGI`'s own translation and defaults do not run.
- **Legal sex.** `sex` must already be `M`, `F`, or `X`. `MALE` / `FEMALE` are not translated. `source` must already be the `#9000030` IEN. `DATE ENTERED` (field `3`) is the client's `Date.today`, not the server's `DT`. `SETLSEX^AUPNSOG3` is not called.
- **MBI write.** The MBI is uppercased here, the way `ADDMBI^AUPNMBI` uppercases it before `UPDATE^DIE`. `DATE ENTERED` is the client's today. `ENTERED BY` is the signed-on `DUZ`; there is no RPC when the client has no `DUZ`. `source`, when given, is filed as field `2` and is not defaulted when omitted. Field `1`'s triggers and xrefs fire. Any other check inside `ADDMBI^AUPNMBI` does not run. An 11-character alphanumeric check is local; FileMan can still refuse the value, and that comes back as `:filer_failed`.
- **MBI read.** This is DDR LISTER, not `GETMBI`/`HISTMBI^AUPNMBI`. Rows are the subfile as stored (`effective_date`, `mbi`, `source`). A "current MBI" choice those tags might make is not applied. A failed read raises `Client::RpcError`; it is not turned into `[]`.
- **Holidays.** `.01` DATE (DINUM) and `2` NAME are the fields that are filed. NAME longer than 30 characters, or blank, is refused before any RPC. `GO^SDHOL`'s interactive `DIC`/`DIE`, and any default it would stuff, does not run. The `B` xref is the file's only xref and FileMan maintains it. Remove looks that xref up with DDR LISTER and deletes by editing `.01` to `"@"`. A date with no row is `:not_found` and does not file. A failed lookup raises; it is not reported as not-found.

## Sex

`SEXELIG^AGUTL` (`AGUTL.m:51`) copies `#2` `.02` into the MCR/MCD/RRE eligibility sub-files (for example `#9000003.11` `.08`). `AG2A.m:58-64` also clears `#9000001` `.23`. That cascade is not a cross-reference on `#2` `.02`, so a DDR FILER write of `.02` would leave eligibility behind. `Registration.set_sex` is resolution 3 and sends no RPC.

`Registration.update(dfn, sex:)` (and `Patient.update`) goes through `Agg.update_patient` / `AGG UPDATE PATIENT` (`UPD^AGGPTUPD`). That RPC files `#2` `.02` from the window parameter `AGGPTSEX` and does not call `SEXELIG^AGUTL`. Passing `sex:` there is not a substitute for `SEXELIG^AGUTL`.

## Undo check-in

`Scheduling.undo_checkin` is resolution 1. It calls `BSDX CHECKIN APPOINTMENT` with check-in time `"@"` and the same eight formals as `checkin_appointment`. `CHECKIN^BSDX25` takes the `"@"` branch and calls `CANCHKIN^BSDX25`, including `BEFORE`/`AFTER^SDAMEVT`. Nothing in that path is reimplemented, and nothing it does is skipped.
