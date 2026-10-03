# ADR 0007: Call each RPC through the broker it was written for

**Status:** Proposed
**Date:** 2026-10-02
**Relates to:** rpms-rpc#282 (prove `BmxClient`), rpms-rpc#258 (bind each package's broker option), rpms-rpc#224 (live proof), [ADR 0002](0002-verified-routine-policy.md)

## Context

RPMS has one RPC registry (`#8994`) and three brokers in front of it. In HTTP
terms an RPC is an endpoint and a broker is a gateway: each accepts a
connection, signs the user on through Kernel, looks the RPC up, runs it and
returns the reply.

| Broker | Built for | What it adds |
|---|---|---|
| XWB | CPRS and other stock VistA desktop clients | Plain replies: a value, a list, a block of text |
| CIA | The VueCentric component framework | A shared session for many components: context, events |
| BMX | IHS's .NET applications (registration, scheduling, behavioral health, referrals, population health) | Table-shaped replies (a typed column header, then records) and a broker-managed error channel |

Because the registry is shared, **any broker will run any RPC** its session's
context option lists. That makes it easy to assume the brokers are
interchangeable. This gem's README said so: "They differ only in wire framing."

They are not interchangeable, because part of an RPC's contract can live in
the broker it was written for.

### What we saw

The registration RPCs (`AGG *`) report some failures by setting a variable,
`BMXSEC`, that belongs to the BMX broker. BMX clears it before every call and
returns its contents as an error (`CALLP^BMXMBRK`; `BmxClient` already raises on
it as a "BMX security error"). The CIA broker neither clears it nor reads it.

Live, on a local YottaDB container of a built 9.0 image, calling
`AGG ADD NEW PATIENT` over CIA as a programmer-key user, with synthetic patients:

| Call | Reply | What was filed |
|---|---|---|
| A parameter the window does not define | success | name only |
| A valid call next, on the same connection | success | last name only |
| The same valid call on a fresh connection | success | everything |

So over CIA a rejected call reads as a success, and it damages the next call on
that connection. The routines are stock; nothing is wrong with them on the
broker they were written for.

### How much of the gem this touches

Of the 191 registered RPCs the gem names (measured against a built image's
registry and option file):

- **116** are served by the chart contexts (`CIAV VUECENTRIC`,
  `OR CPRS GUI CHART`) or are sign-on calls. The gem signs on over CIA under the
  chart's context and calls them the way the chart does.
- **75** are served only by an application's own broker option: `AMHG` 40
  (`AMHGRPC`), `BMC` 21 (`BMCRPC`), `BSDX` 9 (`BSDXRPC`), `AGG` 4 (`AGGRPC`),
  `BQI` 1 (`BQIRPC`). Those applications are BMX clients. The gem sends all 75
  over CIA.

The strength of the evidence differs by namespace. `AGG` and `BQI` entry
routines use `BMXSEC`. `AMHG` and `BSDX` return BMX's table format and their
entry routines do not reference `BMXSEC`, though the routines they call were not
read. Two of the 21 `BMC` entry routines use `BMXSEC`.

## Decision

1. **Every RPC has a home: a broker and a context option.** The home is the one
   its own client uses. It is recorded with the mapping or the API module, from
   evidence: the option that lists the RPC, and the conventions its routine
   uses.
2. **The gem calls an RPC through its home broker under its home context.**
   Chart and sign-on RPCs go over CIA (or XWB on stock VistA). The BMX
   applications' RPCs go over BMX.
3. **Calling an RPC through another broker is a deviation, and is said so.**
   It is allowed only where the home broker is not served (a backend with no BMX
   listener), and then:
   - reads are labelled "not the home broker" wherever results are reported;
   - a write uses a fresh connection, sends only parameters the RPC's own
     definition allows, and is followed by a read-back before it is reported as
     filed.
4. **Evidence names its broker.** A live result, a wire capture or a coverage
   number says which broker produced it. A pass over CIA is not proof for an RPC
   whose home is BMX.
5. **A session that needs both brokers holds one connection to each**, as a
   workstation running the chart beside the registration application does.

## Consequences

### Positive

- A test over the home broker tests RPMS, not a path only this gem takes.
- Errors arrive where the RPC put them.
- The rule is checkable: a mapping without a home, or a call routed away from
  it without the deviation label, can fail a test.

### Negative

- `BmxClient` has to be proven end to end first (rpms-rpc#282). Until then the
  75 RPCs are deviations by this ADR's own terms.
- A backend with no BMX listener cannot give home-broker proof for those 75.
- Two connections per user affects the session pool (ADR 0005, ADR 0006).

### Alternatives considered

- **One broker for everything (today).** Simplest, and wrong in the way shown
  above: it cannot see the failures the home broker reports.
- **Patch the routines to report errors in the reply body.** That changes stock
  RPMS code to suit this client. Rejected: the client follows RPMS.

## Open questions

- Does the chart itself call any of these namespaces over CIA? A recording of
  its calls on a built image would settle it; any it does call have CIA as a
  legitimate home.
- For `AMHG`, `BSDX` and the rest of `BMC`: do the routines they call depend on
  BMX the way `AGG` does?

## References

- `M Transfer/Routines/BMXMBRK.m` (`CALLP`), `BMXMON.m`: the BMX broker clears
  and returns `BMXSEC`.
- `Patient Registration GUI/Routines/AGGPTADD.m`, `AGGPTUPD.m`: set `BMXSEC` on
  a parameter the window does not define, and stop processing parameters while
  it is set.
- `lib/rpms_rpc/bmx_client.rb`: reads the security error and raises.
- `lib/rpms_rpc/api/agg.rb`: the context binding, and the session-hygiene note
  this ADR explains.
