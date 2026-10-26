#!/bin/sh
# ./build.sh [app|debug|dev|test <pkg>|tool <name>|c] — all builds use the fc collection.
# Every target first compiles the vendored C libraries: each vendor/<lib>/fc_<lib>.c is one translation
# unit, built into build/fc_<lib>.obj (.o on macOS) when anything under vendor/<lib> is newer, and
# linked by the Odin package that foreign-imports it. `c` does only that step. Needs clang (macOS: Xcode
# command line tools) or, on Windows, clang or MSVC's cl.
set -e
cd "$(dirname "$0")"
mkdir -p build
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
EXE=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXE=.exe ;; esac

build_c() {
  for src in vendor/*/fc_*.c; do
    name=$(basename "$src" .c)
    if [ -n "$EXE" ]; then obj=build/$name.obj; else obj=build/$name.o; fi
    if [ -f "$obj" ] && [ -z "$(find "$(dirname "$src")" build.sh -newer "$obj" | head -1)" ]; then continue; fi
    echo "cc $src"
    # Optional fc_<lib>.cflags: one line of extra -I/-D flags (paths from the repo root).
    extra=""
    [ -f "${src%.c}.cflags" ] && extra=$(tr -d '\r\n' < "${src%.c}.cflags")
    if [ -z "$EXE" ]; then
      # Both architectures in one object, for the universal macOS app.
      clang -c -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 $extra -o "$obj" "$src"
    elif command -v clang >/dev/null 2>&1; then
      clang -c -O2 -D_CRT_SECURE_NO_WARNINGS $extra -o "$obj" "$src"
    else
      cl -nologo -c -O2 -D_CRT_SECURE_NO_WARNINGS $extra -Fo"$obj" "$src"
    fi
  done
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
