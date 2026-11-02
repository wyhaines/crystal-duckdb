#!/usr/bin/env bash
# Compile and run every README Crystal fence as an independent program.
# Set LIBRARY_PATH and LD_LIBRARY_PATH to the selected DuckDB library.
# Optional CRYSTAL_SPEC_CPUS restricts compilation and execution via taskset.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export CRYSTAL_CACHE_DIR=${CRYSTAL_CACHE_DIR:-"$root/.cache/crystal"}
export SHARDS_CACHE_PATH=${SHARDS_CACHE_PATH:-"$root/.cache/shards"}
export TMPDIR="$root/.tmp"
mkdir -p -- "$CRYSTAL_CACHE_DIR" "$SHARDS_CACHE_PATH" "$TMPDIR"
exec 9>"$TMPDIR/compile.lock"
flock 9

cd -- "$root"
test -d lib/db || shards install
# Resolve the checkout as an installed shard, without changing the examples.
export CRYSTAL_PATH="$root/src:$root/lib:$(crystal env CRYSTAL_PATH)"
scratch=$(mktemp -d "$TMPDIR/readme.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

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
  # Cache guard: keep immediately before every compile.
  test -n "$CRYSTAL_CACHE_DIR"
  test -d "$CRYSTAL_CACHE_DIR"
  "${runner[@]}" crystal build "$source" -o "$scratch/example"
  (cd -- "$scratch" && "${runner[@]}" ./example)
  count=$((count + 1))
done
echo "README: $count Crystal programs compiled and ran successfully"
