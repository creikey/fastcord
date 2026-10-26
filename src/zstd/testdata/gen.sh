#!/bin/sh
# Regenerates the zstd test vectors (zstd 1.5.7 CLI + libzstd from Homebrew).
# gw.c links libzstd only to *produce* gateway-style streams; the decoder is pure Odin.
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
python3 -I genjson.py blob sample.json 1 40000
# sample.bin / random.bin: deterministic mixed binary, see git history of this script
for l in 1 3 9 19; do zstd -q -f -$l sample.json -o sample.json.$l.zst; done
zstd -q -f --long=27 -5 sample.json -o sample.json.long.zst
cat sample.json | zstd -q -7 --no-check > sample.json.stream.zst   # no content size
zstd -q -f -1 sample.bin -o sample.bin.1.zst
zstd -q -f -19 sample.bin -o sample.bin.19.zst
head -c 300000 /dev/zero | zstd -q -3 > zeros.zst                   # RLE blocks
zstd -q -c -3 random.bin > random.zst                                # raw blocks
printf '' | zstd -q -c > empty.zst
# Gateway: one endless frame, ZSTD_e_flush after each message (like Discord's zstd-stream).
cc -O2 gw.c -I/opt/homebrew/opt/zstd/include -L/opt/homebrew/opt/zstd/lib -lzstd -o $T/gw
python3 -I genjson.py msgs $T/gwmsgs.bin 3 120
$T/gw $T/gwmsgs.bin gw3.zst gw3.idx 3 23
$T/gw $T/gwmsgs.bin gw19.zst gw19.idx 19 23
zstd -q -19 -c $T/gwmsgs.bin > gwmsgs.bin.zst
rm -rf $T
