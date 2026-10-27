#!/bin/sh
# Compile one module's smoke file (jai/tests/sm/<module>.jai); prints the compiler output.
# dead_code_elimination is off in build.jai, so every procedure in the module is type-checked.
cd "$(dirname "$0")/../.."
exec /opt/jai/bin/jai-macos build.jai -quiet - run jai/tests/sm/$1.jai 2>&1 | grep -v "^cc "
