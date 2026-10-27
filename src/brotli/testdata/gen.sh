#!/bin/sh
# Regenerates the brotli test vectors (brotli 1.2.0 CLI from Homebrew).
# text.txt = brotli's README.md + LICENSE; sample.json = first 24000 bytes of
# ../../zstd/testdata/sample.json; sample.bin/random.bin copied from there too.
set -e
cd "$(dirname "$0")"
for q in 0 1 2 3 4 5 6 7 8 9 10 11; do brotli -f -q $q text.txt -o text.txt.q$q.br; done
for q in 0 1 2 5 9 11; do brotli -f -q $q sample.json -o sample.json.q$q.br; done
brotli -f -q 11 -w 10 sample.json -o sample.json.q11w10.br
brotli -f -q 5 -w 24 sample.json -o sample.json.q5w24.br
for q in 1 6 11; do brotli -f -q $q sample.bin -o sample.bin.q$q.br; done
brotli -f -q 5 random.bin -o random.bin.q5.br   # uncompressed meta-blocks
printf '' > empty && brotli -f -q 5 empty -o empty.br && rm empty
