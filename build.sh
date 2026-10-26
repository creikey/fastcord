#!/bin/sh
# ./build.sh [app|test <pkg>|tool <name>] — all builds use the fc collection.
set -e
cd "$(dirname "$0")"
mkdir -p build
FLAGS="-collection:fc=src -vet-shadowing -strict-style"
case "${1:-app}" in
  app)  odin build src/app -out:build/fastcord $FLAGS -o:speed ;;
  debug) odin build src/app -out:build/fastcord-debug $FLAGS -debug ;;
  test) odin test "src/$2" $FLAGS -out:build/test-$(echo $2 | tr / _) ;;
  tool) odin build "tools/$2" -out:build/$2 $FLAGS ;;
  *) echo "usage: $0 [app|debug|test <pkg>|tool <name>]"; exit 2 ;;
esac
