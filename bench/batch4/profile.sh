#!/bin/sh
set -eu
# bench/run.py starts the server from the project root.
export RELEASE_BOOT_SCRIPT_CLEAN=start
exec "${BATCH4_RELEASE:?Set BATCH4_RELEASE to the release executable}" eval \
  'Code.require_file("bench/batch4/write_probe.exs")'
