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
# ChaCha20 must take tls.CHACHA20_IMPL: the default AVX2 one crashes in Windows debug builds.
if grep -rnE 'chacha20poly1305\.init|chacha20\.init\(|aead\.init\(|_oneshot\(\.X?CHACHA' src --include=*.odin | grep -vE 'CHACHA20_IMPL|aead_impl'; then
  echo "FAIL ChaCha20 above without tls.CHACHA20_IMPL / tls.aead_impl"; fail=1
fi
# FASTCORD_CI=1 skips what needs a GPU, audio devices or the gg sans font cache (UI scripts).
for pkg in locks prof netio tls quic quic/h3 quic/altsvc http etf zstd brotli protobuf imagefmt vector ui gfx audio media discord voice voice/mls voice/dave opus lottie app; do
  [ -d "src/$pkg" ] || continue
  if [ -n "$FASTCORD_CI" ]; then case $pkg in gfx|audio|media|app) continue;; esac; fi
  ls src/$pkg/*_test.odin >/dev/null 2>&1 || continue
  out="build/test-$(echo $pkg | tr / _)"
  if odin test "src/$pkg" -collection:fc=src -vet-shadowing -strict-style -debug -out:"$out$EXE" > "$out.log" 2>&1; then
    echo "PASS $pkg"
  else
    echo "FAIL $pkg (see $out.log)"; tail -25 "$out.log" | sed 's/^/    /'; fail=1
  fi
done
[ -n "$FASTCORD_CI" ] || tests/ui/run.sh || fail=1
# UI benchmark counters against tests/bench/budget.json (needs the font cache, like the UI scripts).
if [ -z "$FASTCORD_CI" ]; then
  if tools/bench.sh > build/bench.log 2>&1; then echo "PASS bench budget"; else echo "FAIL bench (see build/bench.log)"; tail -15 build/bench.log | sed 's/^/    /'; fail=1; fi
fi
exit $fail
