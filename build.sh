#!/bin/sh
# ./build.sh [app|debug|dev|test <pkg>|tool <name>|c] — all builds use the fc collection.
# Every target first compiles the vendored C (vendor/wuffs) into build/, which Odin links; `c` does
# only that step. Needs clang (macOS: Xcode command line tools) or, on Windows, clang or MSVC's cl.
set -e
cd "$(dirname "$0")"
mkdir -p build
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac

C_SRC="vendor/wuffs/fc_wuffs.c vendor/wuffs/wuffs-v0.4.c"
build_c() {
  if [ -n "$EXE" ]; then obj=build/fc_wuffs.obj; else obj=build/fc_wuffs.o; fi
  stale=0
  for f in $C_SRC build.sh; do [ "$obj" -nt "$f" ] || stale=1; done
  [ $stale = 1 ] || return 0
  if [ -n "$EXE" ]; then
    # Scalar code on Windows: clang 11's MSVC-mode headers lack the AVX2 types Wuffs' SIMD paths use,
    # and MSVC needs /arch:AVX2 for them.
    if command -v clang >/dev/null 2>&1; then
      clang -c -O2 -std=c99 -DWUFFS_CONFIG__AVOID_CPU_ARCH -o $obj vendor/wuffs/fc_wuffs.c
    else
      cl -nologo -c -O2 -DWUFFS_CONFIG__DISABLE_MSVC_CPU_ARCH__X86_64_FAMILY -Fo"$obj" vendor/wuffs/fc_wuffs.c
    fi
  else
    # Both architectures in one object, for the universal macOS app.
    clang -c -O2 -std=c99 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -o $obj vendor/wuffs/fc_wuffs.c
  fi
}
build_c

case "${1:-app}" in
  app)  odin build src/app -out:build/fastcord$EXE $FLAGS -o:speed ;;
  debug) odin build src/app -out:build/fastcord-debug$EXE $FLAGS -debug ;;
  dev) odin build src/app -out:build/fastcord-dev$EXE $FLAGS -debug -o:speed ;;
  test) odin test "src/$2" $FLAGS -out:build/test-$(echo $2 | tr / _)$EXE ;;
  tool) odin build "tools/$2" -out:build/$2$EXE $FLAGS ;;
  c) ;;
  *) echo "usage: $0 [app|debug|dev|test <pkg>|tool <name>|c]"; exit 2 ;;
esac
