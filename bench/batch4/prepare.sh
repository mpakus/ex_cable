#!/bin/sh
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/../.." && pwd)
dest=${1:?Usage: prepare.sh NEW_DIRECTORY [stock|batch4]}
mode=${2:-batch4}
case "$mode" in
  stock|batch4) ;;
  *) echo "Expected stock or batch4" >&2; exit 2 ;;
esac
mkdir "$dest"
dest=$(CDPATH='' cd "$dest" && pwd)
git -C "$root" archive --output="$dest/source.tar" b31bb1b \
  lib config rel test mix.exs mix.lock .tool-versions .formatter.exs
tar -xf "$dest/source.tar" -C "$dest"
rm "$dest/source.tar"
cp -R "$root/deps" "$dest/"
if [ "$mode" = batch4 ]; then
  git -C "$root" show 7c3abd8:bench/batch4/batch4_test.exs > "$dest/test/batch4_test.exs"
  (cd "$dest" && patch -p1 < "$root/bench/batch4/batching.patch")
fi
