#!/bin/sh
# Runs every package's unit tests, then the headless UI scripts. Exits non-zero on any failure.
# Live network tests stay off unless FASTCORD_LIVE=1 is set by the caller.
cd "$(dirname "$0")/.."
mkdir -p build
fail=0
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac
# Mutexes and condition variables must be fc:locks ones, which catch misuse instead of deadlocking.
if grep -rnE 'sync\.(Mutex|Cond|RW_Mutex|Recursive_Mutex|mutex_|cond_|guard\()' src --include=*.odin | grep -v '^src/locks/'; then
  echo "FAIL raw core:sync locks above; use fc:locks"; fail=1
fi
# FASTCORD_CI=1 skips what needs a GPU, audio devices or the gg sans font cache (UI scripts).
for pkg in locks netio tls quic quic/h3 quic/altsvc http etf zstd brotli protobuf imagefmt vector ui gfx audio media discord voice voice/mls voice/dave opus lottie app; do
  [ -d "src/$pkg" ] || continue
  if [ -n "$FASTCORD_CI" ]; then case $pkg in gfx|audio|media|app) continue;; esac; fi
  ls src/$pkg/*_test.odin >/dev/null 2>&1 || continue
  out="build/test-$(echo $pkg | tr / _)"
  if odin test "src/$pkg" -collection:fc=src -vet-shadowing -strict-style -debug -out:"$out$EXE" > "$out.log" 2>&1; then
    echo "PASS $pkg"
  else
    echo "FAIL $pkg (see $out.log)"; fail=1
  fi
done
[ -n "$FASTCORD_CI" ] || tests/ui/run.sh || fail=1
exit $fail
