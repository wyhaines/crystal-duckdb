#!/usr/bin/env bash
# Reproduce one Linux amd64 CI cell using Crystal and shards from PATH.
# Usage: scripts/ci-local.sh <1.5.6|2.0.0> <download-directory> [spec arguments...]
# Example: PATH=/path/to/crystal/bin:$PATH scripts/ci-local.sh 2.0.0 "$PWD/.tmp"
# Optional CRYSTAL_SPEC_CPUS restricts compilation and specs via taskset.
set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: $0 <1.5.6|2.0.0> <download-directory> [spec arguments...]" >&2
  exit 2
fi

version=$1
download_dir=$2
shift 2

case "$version" in
  1.5.6)
    archive=libduckdb-linux-amd64.zip
    sha256=b845005f5132a7d8180057c35e14a7626632258782f871a90861b19c1c03841b
    ;;
  2.0.0)
    archive=duckdb-shared-libs-linux-amd64.tar.gz
    sha256=993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1
    ;;
  *)
    echo "Unsupported DuckDB version: $version (expected 1.5.6 or 2.0.0)" >&2
    exit 2
    ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p -- "$download_dir"
download_dir=$(cd -- "$download_dir" && pwd)
archive_path="$download_dir/v$version-$archive"
library_dir="$download_dir/duckdb-$version"

crystal_version=$(crystal --version | awk 'NR == 1 {print $2}')
export CRYSTAL_CACHE_DIR="$root/.cache/crystal-$crystal_version"
export SHARDS_CACHE_PATH="$root/.cache/shards"
export TMPDIR="$root/.tmp"
mkdir -p -- "$CRYSTAL_CACHE_DIR" "$SHARDS_CACHE_PATH" "$TMPDIR"
# Serialize extraction, dependency installation, and compilation in this checkout.
exec 9>"$TMPDIR/compile.lock"
flock 9

url="https://github.com/duckdb/duckdb/releases/download/v$version/$archive"
echo "Downloading $url"
curl --fail --location --silent --show-error --retry 3 "$url" --output "$archive_path"
printf '%s  %s\n' "$sha256" "$archive_path" | sha256sum --check --strict
# Never extract an archive until its digest has passed verification.
mkdir -p -- "$library_dir"
case "$archive" in
  *.zip) unzip -q -o "$archive_path" -d "$library_dir" ;;
  *.tar.gz) tar -xzf "$archive_path" -C "$library_dir" ;;
esac
test -f "$library_dir/libduckdb.so"
export LIBRARY_PATH="$library_dir"
export LD_LIBRARY_PATH="$library_dir"

python3 - "$library_dir/libduckdb.so" <<'PY'
import ctypes
import sys

library = ctypes.CDLL(sys.argv[1])
library.duckdb_library_version.restype = ctypes.c_char_p
print("duckdb_library_version():", library.duckdb_library_version().decode(), flush=True)
PY

cd -- "$root"
crystal --version
shards install
# These files are created by the specs; stale databases make runs share state.
rm -f -- test.db '[:memory:]'
echo "Running crystal spec (cache: $CRYSTAL_CACHE_DIR)"
spec_command=(crystal spec "$@")
if [[ -n ${CRYSTAL_SPEC_CPUS:-} ]]; then
  spec_command=(taskset -c "$CRYSTAL_SPEC_CPUS" "${spec_command[@]}")
fi
# Cache guard: keep immediately before every compile.
test -n "$CRYSTAL_CACHE_DIR"
test -d "$CRYSTAL_CACHE_DIR"
exec "${spec_command[@]}"
