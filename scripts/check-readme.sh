#!/usr/bin/env bash
# Compile and run every README Crystal fence as an independent program.
# Set LIBRARY_PATH to the selected DuckDB directory; also LD_LIBRARY_PATH on Linux.
# Optional CRYSTAL_SPEC_CPUS restricts compilation and execution via taskset.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/ci-common.sh"
export CRYSTAL_CACHE_DIR=${CRYSTAL_CACHE_DIR:-"$root/.cache/crystal"}
export SHARDS_CACHE_PATH=${SHARDS_CACHE_PATH:-"$root/.cache/shards"}
export TMPDIR="$root/.tmp"
mkdir -p -- "$CRYSTAL_CACHE_DIR" "$SHARDS_CACHE_PATH" "$TMPDIR"
scratch=
trap 'rm -rf -- "$scratch"; release_compile_lock' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
acquire_compile_lock
set_duckdb_link_args

cd -- "$root"
test -d lib/db || shards install
# Resolve the checkout as an installed shard, without changing the examples.
export CRYSTAL_PATH="$root/src:$root/lib:$(crystal env CRYSTAL_PATH)"
scratch=$(mktemp -d "$TMPDIR/readme.XXXXXX")

python3 - "$root/README.md" "$scratch" <<'PY'
from pathlib import Path
import re
import sys

readme, scratch = map(Path, sys.argv[1:])
blocks = []
code = None
for line_number, line in enumerate(readme.read_text().splitlines(keepends=True), 1):
    if code is None and re.fullmatch(r"```crystal\s*", line):
        code = []
        start = line_number + 1
    elif code is not None and re.fullmatch(r"```\s*", line):
        blocks.append((start, "".join(code)))
        code = None
    elif code is not None:
        code.append(line)
if code is not None:
    raise SystemExit("Unclosed Crystal fence in README.md")
if not blocks:
    raise SystemExit("No Crystal examples found in README.md")
for index, (start, code) in enumerate(blocks, 1):
    (scratch / f"snippet-{index:02d}-line-{start}.cr").write_text(code)
print(f"Checking {len(blocks)} README Crystal programs", flush=True)
PY

runner=()
if [[ -n ${CRYSTAL_SPEC_CPUS:-} ]]; then
  runner=(taskset -c "$CRYSTAL_SPEC_CPUS")
fi
count=0
for source in "$scratch"/snippet-*.cr; do
  echo "Compiling ${source##*/}"
  # The alternate expansions support empty arrays under Bash 3.2 with nounset.
  # Cache guard: keep immediately before every compile.
  test -n "$CRYSTAL_CACHE_DIR"
  test -d "$CRYSTAL_CACHE_DIR"
  ${runner[@]+"${runner[@]}"} crystal build "$source" -o "$scratch/example" ${duckdb_link_args[@]+"${duckdb_link_args[@]}"}
  (cd -- "$scratch" && ${runner[@]+"${runner[@]}"} ./example)
  count=$((count + 1))
done
echo "README: $count Crystal programs compiled and ran successfully"
