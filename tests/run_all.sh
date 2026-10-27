#!/bin/sh
# Runs every package's unit tests, then the headless UI scripts. Exits non-zero on any failure.
# Never touches the network: live tests (FASTCORD_LIVE) are switched off here even
# if the caller's environment sets it, and the live parity session
# (src/discord/parity/session.sh) is a separate manual tool that nothing here runs.
# Traffic parity runs offline: the discord package's parity_* tests replay traffic/*.jsonl.
unset FASTCORD_LIVE
cd "$(dirname "$0")/.."
mkdir -p build
./build.sh c || exit 1
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
# Each package's test binary builds and runs as its own job, all in parallel;
# results print in a fixed order afterwards.
PKGS="locks netio tls quic quic/altsvc http etf zstd brotli protobuf imagefmt vector qr ui gfx audio media discord voice voice/mls voice/dave opus lottie app"
run_pkg() {
  pkg=$1; out="build/test-$(echo $pkg | tr / _)"; t0=$(date +%s)
  if odin test "src/$pkg" -collection:fc=src -vet-shadowing -strict-style -debug -out:"$out$EXE" > "$out.log" 2>&1; then
    echo "PASS $pkg ($(( $(date +%s) - t0 ))s)" > "$out.res"
  else
    { echo "FAIL $pkg ($(( $(date +%s) - t0 ))s, see $out.log)"; tail -25 "$out.log" | sed 's/^/    /'; } > "$out.res"
  fi
}
# The sampling-profiler test needs an idle CPU to collect enough samples: run it alone first.
run_pkg prof
cat build/test-prof.res
grep -q "^FAIL" build/test-prof.res && fail=1
for pkg in $PKGS; do
  [ -d "src/$pkg" ] || continue
  if [ -n "$FASTCORD_CI" ]; then case $pkg in gfx|audio|media|app) continue;; esac; fi
  ls src/$pkg/*_test.odin >/dev/null 2>&1 || continue
  rm -f "build/test-$(echo $pkg | tr / _).res"
  run_pkg "$pkg" &
done
wait
for pkg in $PKGS; do
  res="build/test-$(echo $pkg | tr / _).res"
  [ -f "$res" ] || continue
  cat "$res"
  grep -q "^FAIL" "$res" && fail=1
done
t0=$(date +%s)
if [ -z "$FASTCORD_CI" ]; then
  # one fast-compiling build serves both; the bench gate checks only its deterministic
  # counters, so the check build's slightly slower UI pass doesn't matter here
  ./build.sh check || exit 1
  export FASTCORD_PREBUILT=1 FASTCORD_BIN=./build/fastcord-check$EXE FASTCORD_BENCH_UNPACED=1
  tests/ui/run.sh || fail=1
  # After the UI scripts, not beside them: the bench runs real-time 60 Hz frames, and
  # sharing the CPU with ~50 script processes made the pair 3x slower than in turn.
  if tools/bench.sh > build/bench.log 2>&1; then echo "PASS bench budget" > build/bench.res
  else { echo "FAIL bench (see build/bench.log)"; tail -15 build/bench.log | sed 's/^/    /'; } > build/bench.res; fi
  cat build/bench.res
  grep -q "^FAIL" build/bench.res && fail=1
fi
echo "ui scripts + sweep + bench: $(( $(date +%s) - t0 ))s"
exit $fail
