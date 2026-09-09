# Releasing

`shard.yml` holds the version. `Pylon::VERSION` reads it at compile time and `pylon version` prints it, so the binary, the shard and the tag never disagree.

## Cutting a release

```sh
script/release 0.2.0        # bumps shard.yml, commits, tags v0.2.0
git push origin main v0.2.0
```

The tag push runs `.github/workflows/release.yml`, which refuses a tag that disagrees with `shard.yml`, builds three binaries and publishes them on the release with a `checksums.txt`:

| Asset                | Built by                        |
| -------------------- | ------------------------------- |
| `pylon-linux-amd64`  | `./build-linux.sh amd64`        |
| `pylon-linux-arm64`  | `./build-linux.sh arm64`        |
| `pylon-darwin-arm64` | `script/build-macos` on macos-14 |

Linux binaries are fully static. The mac binaries link everything homebrew supplies as an archive, so a download runs on a mac with neither crystal nor those formulae installed. Both build scripts run locally too, which is the way to check a release build before tagging.

Versions are `major.minor.patch`. The wire protocol has its own version (`Wire::PROTOCOL`) and a client refuses a remote with a different version, so bump the minor version whenever `PROTOCOL` changes and the patch version for anything a running sync would not notice.
