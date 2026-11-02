#!/usr/bin/env bash
# Shared by ci-local.sh and check-readme.sh (also compatible with macOS Bash 3.2).

compile_lock_dir=
acquire_compile_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$TMPDIR/compile.lock"
    flock 9
  else
    # macOS has no flock utility. Atomic mkdir serializes local runs too.
    # Set the cleanup path only after acquisition so a waiter cannot remove it.
    while ! mkdir "$TMPDIR/compile.lock.d" 2>/dev/null; do
      if [[ ! -d $TMPDIR/compile.lock.d ]]; then
        echo "Cannot create compile lock: $TMPDIR/compile.lock.d" >&2
        return 1
      fi
      sleep 1
    done
    compile_lock_dir="$TMPDIR/compile.lock.d"
  fi
}

release_compile_lock() {
  if [[ -n $compile_lock_dir ]]; then
    rmdir "$compile_lock_dir"
  fi
}

set_duckdb_link_args() {
  duckdb_link_args=()
  if [[ $(uname -s) == Darwin ]]; then
    # LIBRARY_PATH names the selected library directory, as on Linux. Explicit
    # -L prevents a Homebrew DuckDB from winning; rpath resolves the official
    # dylib's @rpath/libduckdb.dylib install name without DYLD_* (purged by SIP).
    local quoted_dir
    quoted_dir=$(python3 - "${LIBRARY_PATH:?Set LIBRARY_PATH to the DuckDB directory}" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
)
    duckdb_link_args=(--link-flags "-L$quoted_dir -Xlinker -rpath -Xlinker $quoted_dir")
  fi
}
