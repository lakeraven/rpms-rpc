# Capturing per-rung reference fingerprints

The classifier ranks a target against every `data/fingerprints/references/*.yml`.
This runbook captures one **real** reference fingerprint per bcer rung
(5.0 / 6.1 / 7.0 / 8.0 / 8.3) from that release's live `#8994` registry.

## Principle: capture once, commit, never rebuild

A reference fingerprint is a durable artifact. Capture each rung **once**, stamp
it with the release's DAT sha, and commit it. Conformance checks then run against
the committed file forever — no rung is ever rebuilt just to re-answer "what does
it provide." Re-capture only when a rung is re-cut (new DAT sha).

## Use a per-rung Docker image (build once, reuse)

Booting a rung by restoring its multi-GB DAT every time is slow and can wedge
Docker. Instead, build a **Docker image per rung once** (recipe lives in
rpms-ops, which owns release builds) from that rung's DAT/lock, tagged with the
sha, e.g. `rpms-bcer:8.0-a3dbdc4a`. Thereafter capture is `docker run` → probe →
stop, in seconds. The image is the reusable substrate for both fingerprint
capture and the Tier-2 behavioral suite.

Constraints that remain:

- **Eval license is single-user — one IRIS container at a time.** Capture is
  serial. Never run two rung containers concurrently.
- **Local/private images only.** Publishing IRIS-embedded images needs an
  InterSystems OEM agreement. These images do not leave the build host.
- Build the images serially with memory headroom (a large LR load during a build
  can wedge the Docker daemon).

## Serial capture loop (one rung at a time)

For each rung, with **no other IRIS container running**:

```sh
RUNG=8.0
SHA=a3dbdc4a                      # that rung's DAT/lock sha (provenance)

# 1. Boot the pre-built rung image (single-user).
docker run -d --name bcer-$RUNG rpms-bcer:$RUNG-$SHA
# ... wait for the broker to be ready (host-side healthcheck; do not open a
#     second IRIS session to poll) ...

# 2. Capture the #8994 registry to a dump (read-only; never writes).
export RPMS_RPC_BROKER_HOST=... RPMS_RPC_ACCESS_CODE=... RPMS_RPC_VERIFY_CODE=...
bin/probe_broker --env bcer-$RUNG           # writes data/broker_dumps/bcer-$RUNG_<date>.txt

# 3. Turn the dump into a provenance-stamped reference fingerprint.
bundle exec rake conformance:ingest \
  DUMP=data/broker_dumps/bcer-$RUNG_<date>.txt \
  ENV=references/bcer-$RUNG \
  RELEASE=bcer-$RUNG \
  DAT_SHA=$SHA \
  NOTE="file 8994 export from bcer-$RUNG image"
  # -> data/fingerprints/references/bcer-$RUNG.yml  (release + dat_sha stamped)

# 4. Quiesce and remove the container before the next rung.
docker stop bcer-$RUNG && docker rm bcer-$RUNG

# 5. Commit this rung's reference immediately.
git add data/fingerprints/references/bcer-$RUNG.yml
git commit -m "Add bcer-$RUNG reference fingerprint (DAT $SHA)"
```

Repeat for 5.0, 6.1, 7.0, 8.0, 8.3. The two seed placeholders
(`bcer-5.0.yml`, `bcer-8.0.yml`) are replaced by their real captures as they
land — a real capture has `source.kind: broker_dump` and a `dat_sha`; a seed
says `hand-authored seed placeholder`.

## Verify

After all five land:

```sh
bundle exec rake conformance:probe TARGET=<some fingerprint>.yml
```

The classifier now ranks across all five rungs, so "highest rung satisfied" is a
real answer rather than a floor. For a target, the highest rung where
`conformance:probe ... REQUIRED=references/bcer-<rung>.yml` exits 0 is the answer.

## Do not

- Do not probe a rung while its image is still building (wedges the build).
- Do not run two rung containers at once (eval license).
- Do not hand-edit a captured reference to "fix" a gap — a gap is data. Fix the
  build, re-cut the rung, re-capture.
