#!/bin/sh
# Runs the engine binding tests with AddressSanitizer in the C side (QuickJS and
# the binding). Linux only. The sanitizer runtime is preloaded into the test
# programs alone, not into cargo or the compiler.
set -eu
cd "$(dirname "$0")/.."
host=$(rustc -vV | sed -n 's/^host: //p')
runner=CARGO_TARGET_$(printf '%s' "$host" | tr 'a-z-' 'A-Z_')_RUNNER
runtime=$(cc -print-file-name=libasan.so)
[ -e "$runtime" ] || { echo "libasan.so not found: install the compiler's sanitizer runtime" >&2; exit 1; }
export SW_QUICKJS_ASAN=1
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target/asan}"
# Leak detection is off: the Rust test harness itself is not instrumented.
export "$runner=env LD_PRELOAD=$runtime ASAN_OPTIONS=detect_leaks=0:abort_on_error=1"
exec cargo test --locked -p sw-quickjs --tests "$@"
