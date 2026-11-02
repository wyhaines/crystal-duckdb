#!/usr/bin/env bash
# Reproduce one Linux amd64 or macOS CI cell using Crystal and shards from PATH.
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

platform=$(uname -s)
case "$platform" in
  Linux) library_name=libduckdb.so ;;
  Darwin) library_name=libduckdb.dylib ;;
  *) echo "Unsupported platform: $platform (expected Linux or Darwin)" >&2; exit 2 ;;
esac

case "$version:$platform" in
  1.5.6:Linux)
    archive=libduckdb-linux-amd64.zip
    sha256=b845005f5132a7d8180057c35e14a7626632258782f871a90861b19c1c03841b
    ;;
  2.0.0:Linux)
    archive=duckdb-shared-libs-linux-amd64.tar.gz
    sha256=993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1
    ;;
  1.5.6:Darwin)
    archive=libduckdb-osx-universal.zip
    sha256=e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6
    ;;
  2.0.0:Darwin)
    archive=duckdb-shared-libs-osx-universal.tar.gz
    sha256=14cd63180614cfd961f7959146ecd9087527ff20b67311efdc3fa1c29c18204d
    ;;
  *)
    echo "Unsupported DuckDB version: $version (expected 1.5.6 or 2.0.0)" >&2
    exit 2
    ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/ci-common.sh"
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
trap release_compile_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
acquire_compile_lock

url="https://github.com/duckdb/duckdb/releases/download/v$version/$archive"
echo "Downloading $url"
curl --fail --location --silent --show-error --retry 3 "$url" --output "$archive_path"
if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$sha256" "$archive_path" | sha256sum --check --strict
else
  printf '%s  %s\n' "$sha256" "$archive_path" | shasum -a 256 --check
fi
# Never extract an archive until its digest has passed verification.
mkdir -p -- "$library_dir"
case "$archive" in
  *.zip) unzip -q -o "$archive_path" -d "$library_dir" ;;
  *.tar.gz) tar -xzf "$archive_path" -C "$library_dir" ;;
esac
test -f "$library_dir/$library_name"
export LIBRARY_PATH="$library_dir"
if [[ $platform == Linux ]]; then
  export LD_LIBRARY_PATH="$library_dir"
else
  # -D prints LC_ID_DYLIB, not a filesystem location. Both pinned archives
  # declare @rpath/libduckdb.dylib; fail clearly if a future archive changes it.
  install_names=$(otool -D "$library_dir/$library_name")
  echo "$install_names"
  if ! grep -q '^@rpath/libduckdb\.dylib$' <<< "$install_names"; then
    echo "Unexpected DuckDB install name (expected @rpath/libduckdb.dylib)" >&2
    exit 1
  fi
fi
set_duckdb_link_args

python3 - "$library_dir/$library_name" <<'PY'
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
# Bash 3.2 with nounset needs this expansion for an empty array.
spec_command=(crystal spec ${duckdb_link_args[@]+"${duckdb_link_args[@]}"} "$@")
if [[ -n ${CRYSTAL_SPEC_CPUS:-} ]]; then
  spec_command=(taskset -c "$CRYSTAL_SPEC_CPUS" "${spec_command[@]}")
fi
# Keep the shell alive for the mkdir lock's EXIT cleanup. Linux retains its
# original exec and flock lifetime.
if [[ -n $compile_lock_dir ]]; then
  # Cache guard: keep immediately before every compile.
  test -n "$CRYSTAL_CACHE_DIR"
  test -d "$CRYSTAL_CACHE_DIR"
  "${spec_command[@]}"
else
  # Cache guard: keep immediately before every compile.
  test -n "$CRYSTAL_CACHE_DIR"
  test -d "$CRYSTAL_CACHE_DIR"
  exec "${spec_command[@]}"
fi
