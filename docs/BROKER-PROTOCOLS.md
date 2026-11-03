# RPMS broker wire protocols: XWB, CIA and BMX

**For:** anyone writing an RPMS broker client, in any language.
**Status:** describes what `lib/rpms_rpc/` sends and reads today, checked against the FOIA RPMS routines named below and the live specs in `test/live/`.
Where a fact comes from a measurement rather than the source, the issue that recorded it is cited.
Routine line numbers are from the FOIA RPMS release; a patched routine on a server may have shifted them, so the label is named too.

RPMS has one RPC registry, REMOTE PROCEDURE (#8994), and three brokers in front of it.
Each broker accepts a socket, signs the user on through Kernel, binds a context option, looks the RPC up and runs its `TAG^ROUTINE`.
What differs is the wire: framing, sign-on, how parameters cross, and how errors come back.
Which broker to call an RPC through is a separate question, answered in [ADR 0007](adr/0007-call-each-rpc-through-its-own-broker.md) and the README's [Which broker to use](../README.md#which-broker-to-use).

| | XWB | CIA | BMX |
|---|---|---|---|
| Server routines | `XWBTCPM`, `XWBPRS`, `XWBRW`, `XWBSEC` (RPC Broker) | `CIANBLIS`, `CIANBACT`, `CIANBRPC` (MSC RPC Broker) | `BMXMON`, `BMXMBRK`, `BMXMSEC` (M Transfer) |
| Built for | CPRS and stock VistA clients | The VueCentric chart | IHS .NET applications |
| rpms-rpc class | `RpmsRpc::XwbClient` | `RpmsRpc::CiaClient` | `RpmsRpc::BmxClient` |
| Request prefix | `[XWB]1130` | `{CIA}` + terminator byte | `{BMX}` + lengths |
| Frame terminator | `\x04` (EOT) | `\x7f` (DEL), declared by the client | `\x04` (EOT) |
| Length fields | decimal digits, and one-byte S-PACK | binary `L()` prefix | decimal digits |
| Sign-on | `XUS SIGNON SETUP`, `XUS AV CODE` | `CIANBRPC AUTH` | `XUS SIGNON SETUP`, `XUS AV CODE` |
| Context | `XWB CREATE CONTEXT` (a round trip) | `CTX` field on each frame | `XWB CREATE CONTEXT` (a round trip) |
| Division (`DUZ(2)`) | `XUS DIVISION GET` / `SET` | `CIANBRPC DIVGET` / `DIVSET` | `XUS DIVISION GET` / `SET` |
| Disconnect | `#BYE#` | action `D` | `#BYE#` in a session packet |

**Don't infer the protocol from the port.**
Sites remap ports.
In the deployments this gem is tested against, a YottaDB build serves CIA on 9100 and BMX on 9101, and an IRIS build serves XWB on 9100, BMX on 9101 and CIA on 9200 (`bmx_client.rb:8-10`, `cia_client.rb:45`, and the README's configuration table).
A client that sends the wrong protocol to a port is usually just disconnected, with nothing saying why.

**All three wires are plaintext.**
Access and verify codes are only lightly enciphered (below), and replies carry PHI in the clear.
Reach a broker over a private network, a port forward or a TLS tunnel ([`docs/tls.md`](tls.md)).

Contents:

- [Shared pieces](#shared-pieces): bytes not characters, the XUSRB1 cipher, RPC names, M subscripts
- [XWB](#xwb)
- [CIA](#cia)
- [BMX](#bmx)
- [IRIS and YottaDB differences](#iris-and-yottadb-differences)
- [Common mistakes](#common-mistakes)

Byte notation below: `\xNN` is one byte in hex, and `·` marks a field boundary for reading only; it is not sent.

## Shared pieces

### Lengths count bytes

Every length on all three wires counts **bytes**, not characters.
rpms-rpc builds every frame as a binary (ASCII-8BIT) string for that reason (`xwb_client.rb:124-127`, `bmx_client.rb:134-136`, `cia_client.rb:553`).
A client that counts characters mis-frames the first value with a multibyte character in it, and the broker then reads the rest of the frame as protocol.

### The XUSRB1 cipher

One substitution cipher protects every value the client enciphers: the `access;verify` pair at sign-on (`XUS AV CODE`, `CIANBRPC AUTH`), the option name for `XWB CREATE CONTEXT`, and electronic-signature codes.
The server decodes it with `$$DECRYP^XUSRB1`.
It is obfuscation, not encryption: the table is public and the cipher carries no key.

The table is 20 rows of the same 94 printable characters in different orders, copied from `XUSRB1.m` into `lib/rpms_rpc/xwb_cipher.rb`.
To encipher a string (`xwb_cipher.rb:44-56`):

1. Pick two different row numbers, `a` and `b` (rpms-rpc picks `a` in 0..19 and `b` in 1..19).
2. For each character, find its index in row `a` and write the character at the same index of row `b`.
   A character not in row `a` passes through unchanged.
3. Send `chr(a + 32)` + the substituted text + `chr(b + 32)`.

Deciphering reverses it: the first and last bytes name the rows (`xwb_cipher.rb:79-92`).
The access and verify codes go as one string joined with `;`, enciphered once.

### RPC names

The NAME of a #8994 entry is at most 30 characters: its input transform rejects anything longer (`cia_client.rb:461-463`).
A long name in M source comments (`;EP -- SOME LONG NAME`) is a comment, not a registration; the registered name may be a shortened twin.
Check a name against the server's registry, not against source.

### List subscripts are M code

On XWB and CIA a list parameter becomes an M local array on the server, and the subscript text the client sends is spliced **raw** into an M reference: `XWBPRS` does `S X=A_"("_X_")"` (`LINST`, `XWBPRS.m:153-157`) and `CIANBLIS` does `S RT=RT_"("_SB_")"` (`DOACTION`, `CIANBLIS.m:132`).
So the client must send each subscript as an M literal:

- a canonic number stays bare: `1`, `0`, `-2`, `1.5`;
- anything else is quoted, with embedded quotes doubled: `FILE` is sent as `"FILE"`;
- a multi-level subscript is the levels joined with commas: `"TEXT",1,0`.

rpms-rpc does this in one place per client (`xwb_client.rb:242-247`, `cia_client.rb:840-845`).
A client that sends `FILE` unquoted makes the server evaluate the variable `FILE`.

## XWB

The stock VistA RPC Broker (`XWBTCPM`), the protocol CPRS speaks.
Code: `lib/rpms_rpc/xwb_client.rb`.
Live specs: `test/live/xwb/`.

### Packing

- **S-PACK**: one length byte, then the value. At most 255 bytes (`xwb_client.rb:133-139`).
- **L-PACK**: the length as decimal digits, then the value.
  The header `[XWB]1130` declares a width of **3** digits (its third digit; `PRSP`, `XWBPRS.m:21-36`), so every L-PACK length is exactly 3 digits and a value is at most 999 bytes (`xwb_client.rb:144-159`).
  A longer length written with more digits is read as 3 digits and the rest as protocol.

The header is `[XWB]` + version `1` + type `1` + L-PACK width `3` + return type `0`.

### Connect

Open the socket and send a TCPConnect command (`xwb_client.rb:162-170`).
Chunk `4` is a command; `5` starts the parameters; each literal is `0` + L-PACK + `f`.
The three literals rpms-rpc sends are the client's address, `0`, and an application name:

```
[XWB]1130 · 4 · \x0aTCPConnect · 5 · 0 010 192.0.2.10 f · 0 001 0 f · 0 008 rpms-rpc f · \x04
```

The broker answers `accept` (after the reply header, below).
Anything else is a refusal.

### Calling an RPC

Chunk `2` is the RPC: an S-PACKed RPC version (`\x01` `1`), then the S-PACKed name, then the parameter chunk `5` (`xwb_client.rb:173-199`, parsed by `PRS2` and `PRS5`, `XWBPRS.m:57-113`).
With no parameters the parameter chunk is `4f` (type 4, empty).

```
no parameters      [XWB]1130 · 2 · \x01 1 · \x10 XUS SIGNON SETUP · 5 · 4f · \x04
one literal "8"    [XWB]1130 · 2 · \x01 1 · \x0d ORWPT ID INFO · 5 · 0 001 8 f · \x04
```

Parameter types, by their type byte (`PRS5`, `XWBPRS.m:81-112`):

| Type | Meaning | rpms-rpc |
|---|---|---|
| `0` | literal: one L-PACK value | sends it |
| `1` | reference: the value is an M expression the server **evaluates** (`$$GETV`) | never sends it |
| `2` | list: L-PACK subscript, L-PACK value, repeated | sends it |
| `3` | global: like a list, but built in `^TMP("XWBA",$J,n)` and passed by name | does not send it |
| `4` | empty | sends it for "no parameters" |
| `5` | stream | not implemented by the broker |

Each parameter ends with `f`.
Inside a list, entries after the first start with `t`, and the subscript is an M literal (see [List subscripts are M code](#list-subscripts-are-m-code)):

```
DDR LISTER with { "FILE" => "200", "FIELDS" => ".01" }
[XWB]1130 · 2 · \x01 1 · \x0a DDR LISTER · 5 · 2 006 "FILE" 003 200 · t 008 "FIELDS" 003 .01 · f · \x04

an Array ["a^b", "c"] becomes the list 1 => "a^b", 2 => "c"
... 5 · 2 001 1 003 a^b · t 001 2 001 c · f · \x04
```

Every value crosses by length, so a value may contain `^`, CR or LF.

### Replies

Every reply is written by `SNDERR` and then the data (`XWBRW.m`; read in `xwb_client.rb:262-288`):

```
<len byte> <security text> · <len byte> <application text> · <data> · \x04
```

- Read the two error packets **by their length bytes**, then the data up to EOT.
  A successful reply starts `\x00\x00`.
- A non-empty **security** packet is the broker refusing the RPC itself: `Remote Procedure 'NAME' doesn't exist on the server.` or `... cannot be run at this time.` (no #8994 entry, or INACTIVE; `XWBPRS.m:128-132`), or the context check's refusal (`XWBSEC`).
- A non-empty **application** packet is an application error.
- An M error can also arrive as **data**: `M  ERROR=...` (two spaces), sometimes after a `\x18` byte (`client.rb:783-795`).
- Data lines are separated by CR LF (`client.rb:797-808`).

### Sign-on

1. `XUS SIGNON SETUP`, no parameters.
   It sets up the partition the next call is checked in, so it belongs to each sign-on: a new socket needs it again (`api/authentication.rb:267-274`).
2. `XUS AV CODE`, one literal: the cipher of `access;verify`.
   Line 1 of the reply is the DUZ; `0` means refused, and the reason is on line 4 (`client.rb:363-399`).
3. Bind the division (below), then the context.

Both sign-on RPCs and both division RPCs are in the `XUS SIGNON` option, so they need no context.

### Division (`DUZ(2)`)

As the stock client does (rpms-rpc#450; `client.rb:402-498`; `test/live/xwb/signon_division_live_test.rb`):

1. `XUS DIVISION GET` (`DIVGET^XUSRB2`).
   Line 1 is how many divisions the user must choose from, then one `ien^name^station^default` row each.
   For a user with one division it sets `DUZ(2)` itself and answers `0` with no rows; read the bound division back from line 4 of `XUS GET USER INFO` (`DUZ(2)^name^station`).
2. With several divisions, `XUS DIVISION SET` with the chosen one.
   Send the IEN with a leading backtick (`` `7819 ``): the server looks the value up in the user's own DIVISION multiple with FileMan, and a bare IEN is read as a name or station number and answers `0`.
   It answers `1` only when it set `DUZ(2)`, so the membership check is the server's.

rpms-rpc fails sign-on closed when more than one division exists and none is the default or named.

### Context

`XWB CREATE CONTEXT`, one literal: the cipher of the option name (`client.rb:515-535`).
The reply is `1` on success.
`CRCONTXT^XWBSEC` (`XWBSEC.m:30-41`) refuses an option that does not exist, and one the user may not use (`$$CHK^XQCS`), unless the user holds `XUPROGMODE`.
After that, an RPC runs only if it is in the bound option's RPC list.
Sending an empty name clears the context.

### Disconnect

Send an RPC frame named `#BYE#` (`xwb_client.rb:47-58`), then close.

## CIA

The IHS CIA broker (`CIANBLIS`), the protocol VueCentric speaks.
Code: `lib/rpms_rpc/cia_client.rb`.
Live specs: `test/live/cia_*`, `test/live/signon_division_live_test.rb`.

### Frames

Every request is one frame (`cia_client.rb:583-592`; read by `DOACTION`, `CIANBLIS.m:122-146`):

```
{CIA} · <terminator> · <sequence> · <action> · <field>... · <terminator>
```

- The first 8 bytes are fixed: `{CIA}`, the terminator byte, a one-byte sequence and a one-byte action.
- **The client chooses the terminator.** The broker reads it from byte 6 (`CIA("EOD")=$A(X,6)`, `CIANBLIS.m:128`) and uses it for the rest of the session.
  rpms-rpc uses `\x7f`. See [why not `$C(30)`](#the-terminator-is-x7f-not-c30).
- **The sequence** is one ASCII digit. The broker echoes it as the first byte of the reply, and it is the only correlation the stream carries.
  rpms-rpc cycles `1`..`9`: a counter that reached `10` would put `1` in the sequence slot and `0` in the action slot (`cia_client.rb:567-572`).
- **Actions** (`CIANBACT.m`): `C` connect, `R` RPC, `P` poll, `D` disconnect; also `Q`, `S`, `U` (query, subscribe, unsubscribe), which rpms-rpc does not use.
- **Fields** are triples of `L()`-packed values: NAME, SUBSCRIPT, VALUE.
  A non-numeric NAME sets `CIA(NAME)` (`UID`, `RPC`, `CTX`, `VER`, ...); a numeric NAME `n` sets parameter `Pn` (`CIANBLIS.m:129-134`).
  The field list ends at the terminator byte.

### The `L()` length prefix

`L()` packs a value as (`cia_client.rb:550-565`; read by `TCPREADL`, `CIANBLIS.m:230-236`):

```
header byte = (number of quotient bytes << 4) | (length mod 16)
then the quotient (length div 16) as that many big-endian bytes
then the value
```

| Value | Packed |
|---|---|
| `""` | `\x00` |
| `UID` (3 bytes) | `\x03` `UID` |
| a 30-byte value | `\x1e` `\x01` + 30 bytes (14 + 1×16) |
| a 300-byte value | `\x1c` `\x12` + 300 bytes (12 + 18×16) |

### Connect

Action `C` with three NAME/SUBSCRIPT/VALUE triples (`cia_client.rb:50-69`):

```
{CIA} \x7f 1 C · \x03VER \x00 \x032.0 · \x02LP \x00 \x049100 · \x03UCI \x00 \x0cVEH,EXTERNAL · \x7f
```

- `VER`: the client's protocol version; rpms-rpc sends `2.0`.
- `LP`: the port the client connected to.
- `UCI`: the namespace to run in.
  **On IRIS this must name the namespace RPMS is installed in** (`RPMS` on the builds measured); with the default `VEH,EXTERNAL` an IRIS broker closes the socket on the connect, and the only symptom is "connection closed by server" (rpms-rpc#572, open).
  A YottaDB broker accepts the default.
  rpms-rpc reads it from `RPMS_UCI` only, for now.

`ACTC^CIANBACT` (`CIANBACT.m:5-23`) answers `callback flag^authentication method^server version^case sensitive^context cached`.
rpms-rpc requires only that a reply comes back.

### RPC frames and parameters

Action `R`.
Fields, in this order (`cia_client.rb:695-717`):

1. `UID` = the session UID (see sign-on).
2. `CTX` = the context option, once one has been bound (see [Context](#context-1)).
3. `RPC` = the RPC name.
4. The parameters, numbered from 1:
   - a scalar: NAME `n`, SUBSCRIPT empty, VALUE the value;
   - a list: one triple per entry, all with NAME `n`, SUBSCRIPT the entry's M-literal subscript, VALUE its value.
     An array is sent with subscripts `1`, `2`, ...

```
ORWPT ID INFO "8", then { "FILE" => "200" }, then ["a", "b"], session UID 7
\x03UID \x00 \x017 · \x03RPC \x00 \x0dORWPT ID INFO
· \x011 \x00     \x018
· \x012 \x06"FILE" \x03200
· \x013 \x011    \x01a  · \x013 \x012 \x01b
```

The parameters reach the RPC's routine positionally and by reference (`DORPC^CIANBACT`, `CIANBACT.m:66-78`).
`ACTR` refuses a call with more than 40 parameters (error 7, `CIANBACT.m:53`).

### Replies

The broker writes the sequence echo first, unconditionally (`W SEQ`, `CIANBLIS.m:135`), then one of three shapes (`CIANBLIS.m:259-276`):

| Shape | Bytes |
|---|---|
| data | `<seq> \x00 <data> <terminator>` |
| error | `<seq> \x01 <error lines> <terminator>` |
| nothing | `<seq> <terminator>` |

Read to the terminator, take the first byte as the echo, then branch on the next byte (`cia_client.rb:794-806`):

- **The echo is never data.** If it does not match the sequence just sent, the bytes belong to an earlier reply: skip them (`cia_client.rb:661-672`).
- **`\x01` is an error.** The text is the error number then the message, e.g. `3 Unknown remote procedure: NAME`, `4 Access denied for remote procedure: NAME`, `1 The server has reported the following error: <$ZS>` (`client.rb:97-127`).
  `ACTR` (`CIANBACT.m:42-53`) uses 3 for no #8994 entry, 4 for not runnable in the context, 5 for INACTIVE.
- **An error can follow the `\x00`.** `DATAOUT` writes the ack before the rows, so an M error while writing rows arrives as `\x01` + text after the ack, or after some rows (rpms-rpc#414).
  No data row contains `\x01`: treat the first one in a data body as the error, and drop the rows before it.

How the data is laid out depends on the RPC's return type in #8994 (`DATAOUT`, `CIANBACT.m:104-112`): a single value, or an array written one node per line.
**The CIA socket has no line terminator on either engine**, so `W !` writes nothing: an array RPC whose WORD WRAP is off sends its nodes run together, and only one with WORD WRAP on ends each node in CR (`cia_client.rb:439-452`).
Lines may end in CR LF, bare CR or bare LF; the YottaDB-served broker writes bare CR (`cia_client.rb:853-857`).

A GLOBAL ARRAY reply in BMX recordset form (the BSDX scheduling and AGG registration RPCs) is the nodes with no line breaks: each node ends in `\x1e` and the last node is a lone `\x1f` (`cia_client.rb:17-26`, `:372-381`).
rpms-rpc reads these to the `\x1f` (`call_rpc_global_array`, `cia_client.rb:422-437`).

### Sign-on

**`CIANBRPC AUTH` comes first.** Every non-`CIANB*` RPC is checked by `$$CANRUN^CIANBACT`, which answers 0 while `DUZ` is unset (`CIANBACT.m:137`), so `XUS SIGNON SETUP` or any other RPC sent before AUTH is refused with error 4.
CIA has no `XUS SIGNON SETUP` / `XUS AV CODE` step.

The AUTH frame (`cia_client.rb:107-172`; `AUTH^CIANBRPC`, `CIANBRPC.m:5-67`):

```
UID = 0                 a first sign-on must ask for session 0
RPC = CIANBRPC AUTH
1   = the application: an OPTION (#19) name; rpms-rpc uses CIAV VUECENTRIC
2   = workstation ID, free text (RPMS keeps 40 characters)        optional
4   = the cipher of access;verify
5   = the client's IP address (written to the sign-on log)         optional
```

- **Send `UID` 0.** A non-zero UID asks to reconnect to that session, and fails when its stored user differs (`CIANBRPC.m:48-57`).
- **The application is the context.** AUTH saves P1 as the session's application ID, and `ACTR` falls back to it when a frame names no `CTX` (`CIANBACT.m:43-45`). AUTH refuses an option that does not exist or is out of order (`CIANBRPC.m:27-30`).
- **The reply** is lines (`CIANBRPC.m:11-21`): line 1 `status^text` (0 success, 1 success with verify code expired, 2 logins inhibited, 3 locked, 4 authentication failure, 5 other error), line 2 the session parameters, then the greeting.
  On success line 2 is `UID^netname^site name`: **adopt that UID and send it on every later frame.**
- **The reply does not carry the DUZ.** Ask for it with `CIAVCXUS VIMINFO`, as VueCentric does: one line, `DUZ^NAME^...`, DUZ in piece 1 (`cia_client.rb:174-233`).
  Not `XUS GET USER INFO` (it is not in `CIAV VUECENTRIC`, so it is refused for a user without `XUPROGMODE`), and not `CIANBRPC GETVAR "DUZ"` (it cannot reach the namespace AUTH stores DUZ in, so it always answers `DUZ=`).

### Division (`DUZ(2)`)

As VueCentric does (rpms-rpc#293, #449; `cia_client.rb:235-307`):

1. `CIANBRPC DIVGET` (`CIANBRPC.m:80-89`).
   Line 1 is the division it chose (the user's default, else the first, else the `DUZ(2)` Kernel sign-on set), then `ien^name^station` rows.
   **It is not a pure read:** it calls DIVSET with its choice.
2. `CIANBRPC DIVSET` with an IEN to act in another of the user's divisions.
   It sets `DUZ(2)` for the rest of the session and answers `1`, and **it checks nothing** (`CIANBRPC.m:91-95`): it accepts any number.
   Check that the IEN is one of the rows DIVGET returned before sending it.

Both are `CIANB*` RPCs, which `ACTR` runs under any context.

### Context

There is no context RPC on CIA.
A frame names its context in the `CTX` field, and `ACTR` saves it to the session **before** it checks the RPC (`CIANBACT.m:43-44`):

- a frame without `CTX` runs under the last `CTX` the session saw, or the sign-on application if none;
- so once a client has named a context, it must name one on **every** frame, or a "restore" it thinks it made never happens (`cia_client.rb:325-358`);
- and a frame that names a context and is then refused has still changed the session's context.

An RPC runs only if it is in the option's RPC list, through its submenus (`CANRUN`/`BLDCTX`, `CIANBACT.m:136-152`); `XUPROGMODE` skips the check, and `CIANB*` RPCs are exempt.
Bind only options the signed-on user holds, and treat `4 Access denied for remote procedure` as a refusal of the RPC in that context.

### Keep-alive and disconnect

- **Poll** (action `P`, field `UID`): answers `interval^server time`, the interval from the `CIANB POLLING INTERVAL` parameter (`cia_client.rb:471-486`).
  The listener ends a session that sends nothing for about 45 seconds (measured; `cia_client.rb:473-477`).
- **Disconnect** (action `D`, field `UID`): runs the session logout and stops the listener (`ACTD`, `CIANBACT.m:24-26`).
  Send it before closing: it needs the UID to release the session's locks and `^XTMP` state, and a peer that simply vanishes leaves the listener draining a dead socket until its retry bound while the next connection waits (rpms-rpc#192; `cia_client.rb:594-617`).
  The broker may close before its reply arrives; that is a clean quit.

### One request at a time

A CIA reply has no length, only the terminator, so a reply abandoned mid-read cannot be resynchronized.
rpms-rpc sends one frame and reads its reply under one lock, drops any bytes already waiting before it writes (`cia_client.rb:620-634`), and closes the socket on a read timeout (`client.rb:215-243`).

## BMX

The IHS BMX broker (`BMXMON`), the protocol IHS .NET applications speak.
Code: `lib/rpms_rpc/bmx_client.rb`.
Live specs: `test/live/bmx/`; captured reply frames: `test/fixtures/bmx/replies.yml`.
The framing below was proven against the stock routines on IRIS (rpms-rpc#282), and the replies were captured from a YottaDB build.

### Packets

Two packet forms (`bmx_client.rb:261-281`):

```
monitor packet   {BMX} · LLLLL · body                   LLLLL = body length, 5 digits
session packet   {BMX} · TTTTT · PPPPP · body           PPPPP = body length, TTTTT = PPPPP + 5
```

`SESSMAIN^BMXMON` reads 11 bytes, then 4, then the body by length (`BMXMON.m:210-219`).

### Connect: two packets

1. A **monitor** packet with body `TCPconnect`.
   `MON^BMXMON` starts a session process and hands it the socket. **Nothing is written back.**
2. A **session** packet with body `TCPconnect`.
   The session process answers `accept` (after the reply header, below; `BMXMON.m:220-221`).

```
{BMX}00010TCPconnect
{BMX}0001500010TCPconnect
```

Send both before reading (`bmx_client.rb:48-77`).
A client that sends one packet and waits for a reply hangs: the session process is blocked waiting for its own first packet (rpms-rpc#282).

### Calling an RPC

The session packet body for an RPC is (`bmx_client.rb:138-182`; parsed by `PRSP`, `PRSM`, `PRSA`, `PRSB` in `BMXMBRK.m`):

```
NNN · WKID;WINH;PRCH;WISH;                 protocol header: 3-digit length, then the fields
LLLLL · FLAG · text                         5-digit length of the whole message (these 5 digits,
                                            FLAG and text), then 1 flag byte
text = NAME                                 no parameters
     | NAME ^ MMMMM · (LLL · TYPE · value)…  5-digit block length; per parameter a 3-digit
                                            (value length + 1), a 1-byte type, the value
```

- No separator between the protocol header and the message.
- FLAG `0` means literal parameters only; it is one byte straight after the length.
- The parser splits the name from the parameters at the **first** `^` only, and reads every value by its length, so **a value may contain `^`** (`BMXMBRK.m:82-112`).

```
XUS SIGNON SETUP
015RPMS_RPC;0;0;0;000220XUS SIGNON SETUP

BMX SQL "SELECT NAME FROM NEW_PERSON MAXRECORDS:2"
015RPMS_RPC;0;0;0;000630BMX SQL^000440410SELECT NAME FROM NEW_PERSON MAXRECORDS:2

two values "a^b" and "c"
015RPMS_RPC;0;0;0;000270X Y^000120040a^b0020c
```

Parameter types: `0` literal, the only one rpms-rpc sends.
Type `1` is a reference: the server **evaluates** the value as M (`$$GETV`, `BMXMBRK.m:107`); never send it.
FLAG `1` and `2` with type `2` build local or global arrays (`BMXMBRK.m:108-125`); rpms-rpc does not build them and refuses Array and Hash parameters on BMX (`bmx_client.rb:222-239`).

**A request is at most 512 bytes.** The parsers cut the protocol string at 512 (`M=512`, `BMXMBRK.m:66`); rpms-rpc refuses a longer one rather than let it be truncated (`bmx_client.rb:39-43`, `:163-165`).

### Replies

Same layout as XWB (`bmx_client.rb:283-322`):

```
<len byte> <security text> · <len byte> <application text> · <data> · \x04
```

Read both error packets **by length** before looking for the EOT.
The security text quotes the RPC name, which can contain `\x04`, and a length byte can itself be `\x04`.
Captured (`test/fixtures/bmx/replies.yml`):

```
unknown RPC        ?Remote Procedure 'ZZZ NO SUCH RPC' doesn't exist on the server.\x00\x04
                   (? is the length byte, 63)
EOT in the name    5Remote Procedure 'ZZ\x04ZZ' doesn't exist on the server.\x00\x04
M error as data    \x00\x00M ERROR=SQL^BMXSQL, More actual parameters than formal parameters: ...\x04
```

The security packet also carries `Application context has not been created!` and the context refusal (`BMXMSEC.m:9-28`).
BMX's own M error trap writes `M ERROR=` with **one** space, as data, after two empty error packets; XWB's writes two (`client.rb:783-795`).

**Recordsets.** `BMX SQL` and the other ADO-style reads return a table (`bmx_client.rb:186-220`):

- a header node of column definitions joined by `^`, each a type letter (`T` in every capture; rpms-rpc also accepts `I`, `D` and `F`), a 5-digit width and the column name;
- then one node per row, values joined by `^`;
- every node ends in `\x1e`; the last is a lone `\x1f`;
- no line breaks.

```
rows           \x00\x00T00016NAME\x1eADAM,ADAM\x1eBSTS,PROXY USER\x1e\x1f\x04
two columns    \x00\x00T00015NAME^T00005SEX\x1eUSER,TEST^MALE\x1eMOUSE,MICKEY M^MALE\x1e\x1f\x04
no rows        \x00\x00T00050NAME\x1e\x1f\x04                 an empty result, not an error
M error        \x00\x00T00030M_ERROR\x1e<the error>\x1e\x1f\x04
query error    \x00\x00\x1fFIELD NOT FOUND\x04                text after the \x1f
```

### Sign-on, division and context

The same RPCs as XWB, framed as BMX: `XUS SIGNON SETUP`, then `XUS AV CODE`, then `XUS DIVISION GET`/`SET`, then `XWB CREATE CONTEXT` with the enciphered option name.
Before sign-on, `CHKPRMIT^BMXMSEC` checks RPCs against the `XUS SIGNON` option; `XWB CREATE CONTEXT`, `XUS AV CODE` and a few others are exempt (`BMXMSEC.m:15-27`).
After sign-on an RPC must be in the bound option, for this user (`$$CHK^XQCS`).

### Disconnect

A session packet with body `#BYE#` (`bmx_client.rb:79-93`).

## IRIS and YottaDB differences

The same FOIA routines run on both engines; these are the differences a client sees.

| | IRIS | YottaDB |
|---|---|---|
| CIA `UCI` on connect | must name the RPMS namespace, or the broker closes the socket (rpms-rpc#572) | the default is accepted |
| CIA reply line ends | split on CR LF, CR or LF | bare CR (`cia_client.rb:853-857`) |
| Arguments to one M call | CIA's own cap of 40 (`CIANBACT.m:53`) | the engine's cap of 32 actual arguments also applies, so an RPC whose entry point takes more fails there |

On both engines the CIA socket has no line terminator, so `W !` sends nothing (above).

## Common mistakes

Each of these has been made, by this gem or by another client, and is cited where it was found.

1. **Sending the BMX connect as one packet.** It hangs against stock `MON^BMXMON`. Send the monitor `TCPconnect`, then the session `TCPconnect`, then read (rpms-rpc#282).
2. **Joining parameters with `^` and splitting them again.** Any value containing `^` (a FileMan field list, a `^`-delimited record) is cut into extra parameters. All three brokers frame parameters by length; send them that way (`bmx_client.rb:169-182`).
3. **Using `$C(30)` as the CIA terminator.** <a id="the-terminator-is-x7f-not-c30"></a>`TCPREADL` ends the field list when a field's **header** byte equals the terminator (`CIANBLIS.m:233`). `\x1e` is the header of every value whose length is 14 mod 16 between 16 and 4095 bytes, so a 30-byte value truncated the frame and the broker dropped the session (rpms-rpc#241). `\x7f` has a high nibble of 7, which no header can reach, and never appears in RPMS text (rpms-rpc#244; `client.rb:140-155`). It also no longer collides with the `\x1e` separators inside a recordset reply.
4. **Reading an XWB or BMX reply "to the first EOT".** The error text can contain `\x04`, and a length byte can be `\x04`. Read the two counted packets by length first (`bmx_client.rb:290-298`).
5. **Treating the CIA sequence echo as data.** On an error or no-data reply the echo is the only byte before the terminator, and a digit echo read as line 1 once minted a DUZ out of nothing (`cia_client.rb:765-806`).
6. **Letting the CIA sequence reach 10.** It is one byte; cycle `1`..`9`.
7. **Reusing a session UID on a first CIA sign-on.** Send `UID` 0, then adopt the UID from line 2 of the reply.
8. **Calling `XUS SIGNON SETUP` on CIA before `CIANBRPC AUTH`.** It is refused (`CIANBACT.m:137`). On CIA, AUTH is the whole sign-on.
9. **Reading the CIA DUZ with `XUS GET USER INFO` or `CIANBRPC GETVAR "DUZ"`.** Use `CIAVCXUS VIMINFO`.
10. **Signing on with `BGU AVLOGON`.** It looks like an equivalent of `XUS AV CODE` and is not: it sets `DUZ(0)="@"` before it checks the codes and never clears it. rpms-rpc refuses to send it (`client.rb:379-381`, `test/rpms_rpc/forbidden_auth_rpcs_test.rb`).
11. **Trusting `CIANBRPC DIVSET`.** It sets any number it is given. Check the division against DIVGET's rows first. On XWB/BMX, send the division IEN with a backtick.
12. **Sending `CTX` once.** CIA keeps the last `CTX` it saw; after the first bind, name the context on every frame.
13. **Dropping a CIA socket without action `D`.** The listener holds the dead session until its retry bound, and the next connection waits (rpms-rpc#192).
14. **More than one request in flight.** None of the three carries a request ID (CIA has only its one-byte echo). Leftover bytes from one reply, read as the next call's reply, put a whole session one call late (rpms-rpc#254, #289). Send, read the whole reply, then send again.
15. **Over-long values.** XWB under `[XWB]1130` takes at most 999 bytes per value and 255 for the RPC name; a BMX request takes at most 512 bytes in all. Refuse a value that does not fit instead of letting the broker misread it (rpms-rpc#472).
16. **Unquoted list subscripts.** They are spliced into M code; quote string subscripts.
17. **Sending a reference parameter (type 1).** XWB and BMX evaluate it as M.
18. **Treating a word-wrap-off array reply as lines on CIA.** Its nodes arrive run together; there is no separator to split on.
