# pylon

Two way file sync between a directory on your machine and one on a remote host over ssh.

It watches both sides, works out what changed since the last time they agreed, and moves only what it has to. It is meant for keeping a working copy in step with a remote dev box while you edit, so it favours being correct over being clever.

## Install

Download the binary for your machine from the [releases page](https://github.com/DanielGilchrist/pylon/releases) and put it on your `PATH`:

| Machine        | Asset                |
| -------------- | -------------------- |
| Apple silicon  | `pylon-darwin-arm64` |
| Linux x86_64   | `pylon-linux-amd64`  |
| Linux arm64    | `pylon-linux-arm64`  |

The remote host needs the same version. Both sides check the wire protocol version when they connect and refuse to run if they disagree, so a mismatched pair fails immediately instead of potentially misbehaving.

To build it yourself you need Crystal 1.21 or later:

```sh
crystal build --release -o bin/pylon src/pylon.cr
```

## Usage

One sync, then exit:

```sh
pylon sync ~/code/app user@devbox:/home/ubuntu/app
```

Keep running and sync on every change:

```sh
pylon sync ~/code/app user@devbox:/home/ubuntu/app --watch --state ~/.pylon/app
```

See what a sync would do without touching anything:

```sh
pylon sync ~/code/app user@devbox:/home/ubuntu/app --dry-run
```

### Sync Flags

- `--state <path>` where to keep state from a previous run. Without it every start is cold requiring the whole tree to be rehashed and any discrepencies to be sent in full.
- `--remote-state <path>` the same thing on the remote host.
- `--ignore <path>` repeatable, a path relative to the sync root e.g. `--ignore node_modules --ignore **/*.js`. Certain editor and system files are always ignored: `.DS_Store`, vim swap files, etc.
- `--prefer-local <glob>` and `--prefer-remote <glob>` decide conflicts, repeatable. A single `.` is the fallback for everything else, so `--prefer-local .` means your machine wins unless a more specific rule says otherwise.
- `--watch` keep running and sync on every change, rather than syncing once and exiting.
- `--compression <level>` zstd level for content in both directions, 9 by default.
- `--config` and `--port` are passed through to ssh, so a host that needs an ssh config or a non standard port works the same as it does for ssh itself.
- `--brand <name>` prints a name of your choosing instead of pylon, for wrapping it in your own tooling.

## How it works

pylon keeps a source of truth, the **base**, which is the last conciladated state of both local and remote.

1. Scan both sides at the same time. Untouched subtrees are carried over from the last scan and only what the watched flagged is rehashed.
2. Compare both trees against the base. A path only changed on one side is a change to send to the other. A path both changed is a conflict, see `--prefer-local` and `--prefer-remote` flags in terms of how conflicts are resolved.
3. Work out the cheapest way to send the change, producing a patch against the previous version if the sender still has it, a block patch against the receiver's copy if only the receiver has it, otherwise the whole file. This is using a reimplementation of `rsync`'s algorithm. We compress using zstd before transferring over the wire.
4. The files are written after first checking every file against its digest first, so a patch that rebuilt the wrong bytes is dropped rather than potentially corrupting the file. This is reported to STDERR.
5. Save the new base based on what was resolved, anything that failed to write is picked up next cycle.

Pylon prioritises being explicit and should never silently fail. Anything it cannot verify is skipped and reported, anything it cannot recover from ends the sync with a reason.

With `--watch` the cycle repeats whenever the watcher says something changed, using FSEvents on
mac and inotify on Linux. Bursts are given a moment to settle so a `git checkout` and other bulk
actions are grouped into one sync.

## Development

```sh
crystal spec                # the spec suite
script/check-end-to-end     # the real binaries over a stub ssh
crystal tool format         # run before committing
bin/ameba                   # lint, build it with `shards build ameba` on a fresh clone
```

`AGENTS.md` has the architecture and the principles the code follows. `RELEASING.md` covers cutting a release.
