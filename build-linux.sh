#!/bin/sh
set -e

cd "$(dirname "$0")"
mkdir -p dist

for arch in amd64 arm64; do
  echo "building linux/$arch"
  docker run --rm --platform "linux/$arch" -v "$PWD":/w -w /w crystallang/crystal:1.21.0-alpine sh -c "
    set -e
    apk add --no-cache zstd-static zstd-dev pkgconf >/dev/null
    rm -rf lib .shards
    shards install --production >/dev/null 2>&1
    crystal build --release --static --no-debug -o dist/pylon-linux-$arch src/pylon.cr
  "
done

rm -rf lib .shards
shards install >/dev/null 2>&1
ls -lh dist/
