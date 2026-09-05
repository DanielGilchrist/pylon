# Performance budget, measured 2026-09-05

Real link between a laptop and a Linux dev box (2 vCPU, ext4) through an ssh tunnel: 103 ms RTT, 0.87 MB/s up, 0.78 MB/s down. Tree of ~36.9k files, ~570 MiB. Timing builds (`-Dtiming`) on both ends. Upstream bytes counted with a PATH shim named `ssh` that runs `bin/latency_proxy 0 0 /usr/bin/ssh "$@"`. `bench/flip_wire_bench.cr <repo> <from> <to>` decomposes a branch flip offline through `git cat-file` and matched the shim within 1%.

## Where the time goes

| Phase | Measured | What it is |
|---|---|---|
| wrapper preflight | 3.9 s + ssh 0.23 s warm / 4.5 s cold | three serial cloud CLI calls (2.4 s, 0.8 s, 0.7 s) before pylon starts |
| startup to "ready" | 2.9 to 3.1 s | 1.59 MiB remote tree at 0.78 MB/s ≈ 2.1 s. Server warm scan 0.2 s, local warm full scan 0.27 s, both hidden in parallel. Tree raw 2.5 MiB, 1.1 MiB of it incompressible digests |
| flip A → B, 8081 changes | 7.7 to 8.0 s | settle 1.4 s (waiting out the 1.8 s checkout + 300 ms quiet), write 6.4 s for 4.93 MiB, mirror 1.0 s, scan 0.22 s |
| flip B → A | 13.8 to 14.5 s | write 12.5 s for 10.24 MiB, mirror 1.1 s |
| single file edit, push | 123 to 179 ms | 1 RTT + 20 to 40 ms local. At the floor |
| single file pull | 142 ms (3 MiB file 264 ms) | 1 RTT |
| first ever run, no state | 7.2 s | cold hash both sides 3.5 s, first mirror of 37k clones with read-back verify 3.5 s and 1.6 GiB allocated |

Write phases run at 88 to 94% of link bandwidth. Flips are bandwidth.

Wire per flip:

| A → B, 4.93 MiB | B → A, 10.24 MiB |
|---|---|
| adds 1.79 MiB (845 files) | adds 5.63 MiB (1872 files, 17.8 MiB raw) |
| prefixed frames 2.09 MiB (4742 files) | prefixed frames 3.56 MiB |
| changes list 0.55 + content framing 0.35 MiB | same 0.9 MiB |
| small mods 0.2 MiB | 0.18 MiB |

The 5.63 MiB of adds on the flip back is content the receiver held 20 seconds earlier and unlinked. The sender store prunes to the receiver's current holdings and the receiver keeps nothing.

Other observations:

- Server rescans triggered by inotify during a write hold the server lock 50 to 200 ms, four or five times per flip.
- A pure `clonefile` makes FSEvents report the untouched source with flags 0x419100 (Created|Modified|Cloned) while `stat` is unchanged. The mirror therefore re-dirties exactly the files it just shipped, the runner waits the 300 ms burst quiet and rehashes them all (6177 files, 163 MiB, ~200 ms) because they are provisional. After a pull it happens twice (own writes, then clones). Filtering on Created|Modified being absent would not work, they are set spuriously.
- Every accelerated scan with any dirty path rebuilds the whole cache through `carry_cache` and the `by_digest` index: ~10 ms and 16 MiB at 37k files, 8% of a single-edit cycle.
- Doubled lines for the same file in the watch output were two saves. A headless nvim save and an `echo >>` each produce exactly one cycle.

## Done 2026-09-05 (uncommitted, PROTOCOL 9, checkpoint VERSION 4)

1. **Receiver-side retention.** `Session::RetentionStore` hard links a file into `<state>.retained/<digest>` before the writer removes or overwrites it (`Writer#preserve`, also every file under a removed directory), bounded to 20k entries oldest-first, verified by SHA-256 on read. Before shipping, `Session#transfer` asks the target which of its would-be full sends it can recover (`AvailabilityRequest`/`AvailabilityResponse`, one round trip, only when the full-send payload is at least 256 KiB) and treats the answer as held. `LocalEndpoint#recovered_content` falls back to the store.
2. **Startup resume.** Both checkpoints persist the last exchanged tree (`exchanged`, replacing the never-used `remote_cache`). The client sends `Core::Digests.fingerprint` (canonical, order independent) of it in `Configure.known`; the server answers with `TreeResume` (a delta) when its persisted tree has the same fingerprint, else the full `TreeUpdate`. The server now always opens with its tree, watching or not.

Measured on the real link, same four flips, baseline vs new:

| | baseline | new |
|---|---|---|
| warm startup, one shot | 3.36 to 3.43 s | 1.06 to 1.13 s |
| watch "ready" | 3.3 s | 845 ms |
| bytes back at startup | 1.59 MiB | 0.0 MiB |
| flip A → B (first) | 8.5 s | 8.1 s |
| flip B → A | 14.9 / 14.6 s | 7.8 / 7.9 s (fulls 2389 → 0) |
| flip A → B (second) | 9.1 s | 6.2 s (fulls 1442 → 0) |
| upstream, four flips | 30.35 MiB | 16.94 MiB |

## Levers still open, ranked by seconds saved

3. **Mirror off the critical path.** Retain planned digests concurrently with the transfer and prune after commit. 1.1 to 1.2 s per flip, now ~15% of a flip.
4. **Clone echo cycle.** Drop the FSEvents event only when the mirror recorded that exact path as just cloned and the flag carries ItemCloned. ~0.5 s of wasted work per sync, not user visible.
5. **Preflight.** Run the cloud CLI calls concurrently or cache the instance id (3.9 s → ~1 s). Longer `ControlPersist` so the cold 4.5 s ssh is rarer.
6. **Protocol bytes.** The old-entry digest in every change (the receiver already holds that tree) and the 32 byte digest repeated per content item are ~0.45 MiB incompressible per flip, ~0.5 s.
7. **Smaller.** Skip server rescans while a write is queued. Update the cache and `by_digest` incrementally instead of rebuilding per accelerated scan. Skip the read-back verify on mirror retain (verify on read already exists), which is most of the first-run 3.5 s.

## Simplification (done 2026-09-05, same evening)

One `Session::ContentStore` per endpoint at `<state>.content`, both sides. `keep(path, digest)` snapshots through `Filesystem.snapshot` (clonefile on macOS, hard link on Linux), `holds?`, `holdings`, `content` (SHA verified, forgets on mismatch), and `prune` bounded to `ORPHAN_LIMIT` (20k) digests not in this side's current tree, oldest first. Content enters the store at hash time: `Scan::Scanner` takes a keeper and calls `keep` after every successful digest, so the cold scan seeds it and every rehash keeps the new version. `Pylon::Discard` is the no-op keeper for endpoints without state and for specs. Gone: `RetentionStore`, `DigestDirectory`, `Retention`, `retain`/`prune(holdings)`/`capture_slice`, the `:mirror` parallel context, `LocalEndpoint#mirror` and the mirror phase of the cycle, `Writer#preserve` and its keeper, `Write::Discard`, the clone probe on Linux (a same-device check instead).

`Settled(T)` and `Awaiting(M, T)` replace `PendingSignatures`/`SettledSignatures`, `PendingContents`/`SettledContents`, `PendingHoldings`/`SettledHoldings` and the Proc-based `PendingWrite`. Both expose `await : T | Fault`; `Awaiting` reads the reply from the endpoint's typed channel and returns its `payload` (every response message now has one). Merging into the signatures hash is done by `Session#settle`, and settle-once is the session dropping its reference.

`TreeResume` is gone. `TreeDelta` carries `live`, and a delta arriving before the client's initial tree is the resume.

`DELTA_WAIT_BYTES` and `HOLDINGS_QUERY_BYTES` are one `ROUND_TRIP_WORTH_BYTES`.

Review pass afterwards: the digest question is `AvailabilityRequest`/`AvailabilityResponse` (built by `Session#availability_query`), the store owns its `ORPHAN_LIMIT`, the Linux same-device probe is gone (a failed link is simply not kept), and a custom ameba rule `Style/TernaryWithNil` bans `cond ? nil : x` in favour of `x if cond` or `x unless cond`.

Why the orphan bound exists: with hash-time capture the store holds every version this side has ever hashed. Versions still in the tree cost no space (clone or link of a live file). Versions whose original is gone (orphans) are the only real disk use, about 7k files or 18 MiB per branch flip with deletions, so unbounded they would grow by gigabytes a month. The bound keeps the newest 20k orphans, roughly three flips, so a flip back still recovers everything and older versions are simply sent again. 20k is a judgement, not a measurement.

Net against HEAD for src: roughly 390 insertions, 314 deletions, for both features plus the cleanup. Specs 473.

Re-measured on the real link after the simplification (same four flips): first run with no state 3.6 s (was 7.2 s, the eager mirror is gone), warm startup 1.07 to 1.11 s, watch ready 901 ms, flips 7.1 / 8.1 / 5.0 / 6.7 s (before the cleanup 8.1 / 7.8 / 6.2 / 7.9 s, baseline 8.5 / 14.9 / 9.1 / 14.6 s), upstream 16.94 MiB, identical to before the cleanup. The mirror phase is off the critical path, and once content is held the post-sync echo cycle no longer rehashes anything (the scan skips a snapshot for a digest already held, so no FSEvents clone event fires), which takes care of most of levers 3 and 4. The first flip's scan grew from 0.22 s to 0.6 s because 6200 snapshots now happen inside the rehash, still a net gain of about a second per flip.

Note for the box: the earlier build created `<remote-state>.retained`, which nothing reads any more and can be deleted.
