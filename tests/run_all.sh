#!/bin/sh
# Runs every package's unit tests, then the headless UI scripts. Exits non-zero on any failure.
# Live network tests stay off unless FASTCORD_LIVE=1 is set by the caller.
cd "$(dirname "$0")/.."
mkdir -p build
fail=0
for pkg in netio tls quic quic/h3 quic/altsvc http etf zstd brotli protobuf imagefmt vector ui gfx audio media discord voice voice/mls voice/dave opus lottie app; do
  [ -d "src/$pkg" ] || continue
  ls src/$pkg/*_test.odin >/dev/null 2>&1 || continue
  out="build/test-$(echo $pkg | tr / _)"
  if odin test "src/$pkg" -collection:fc=src -vet-shadowing -strict-style -out:"$out" > "$out.log" 2>&1; then
    echo "PASS $pkg"
  else
    echo "FAIL $pkg (see $out.log)"; fail=1
  fi
done
tests/ui/run.sh || fail=1
exit $fail
