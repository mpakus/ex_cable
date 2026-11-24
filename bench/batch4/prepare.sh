#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
dest=${1:?Usage: prepare.sh NEW_DIRECTORY}
mkdir "$dest"
cp -R "$root/lib" "$root/config" "$root/rel" "$root/test" "$root/deps" "$dest/"
cp "$root/mix.exs" "$root/mix.lock" "$root/.tool-versions" "$root/.formatter.exs" "$dest/"
cp "$root/bench/batch4/batch4_test.exs" "$dest/test/"
cd "$dest"
patch -p1 < "$root/bench/batch4/batching.patch"
