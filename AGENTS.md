# Notes for coding agents

Read README.md first: build, testing, performance and conventions are there. This file lists what is easy to miss.

- Build with `./build.sh dev` (optimised, with symbols). `./build.sh debug` is unoptimised and about 5x
  slower per frame, so never judge speed or input lag with it.
- `tests/run_all.sh` runs every test, the headless UI scripts and the bench budget. Run it before committing,
  along with `python3 -I tools/check_secrets.py`.
- Locks: only `fc:locks`, never raw `core:sync` mutexes (run_all.sh greps for them). The UI thread must never
  wait on network or disk; hand work to a thread and poll.
- UI changes: run `tools/bench.sh` before and after (`--save` first to keep a baseline). Profile with
  `-prof:` and query the stacks with `tools/folded.py`. If the counters grew on purpose, update
  `tests/bench/budget.json` in the same commit. The UI must stay immediate-mode (README "Performance").
- Judge speed by the bench's latency column (input to GPU done, from idle), not by throughput. The fixture
  is shaped like a made-up heavy account; `tools/bench.sh --live` compares it with the real one, read-only.
  Never commit a real account's shape.
- Headless runs (`-shot:`, `-bench`) render offscreen. Check UI changes by looking at the PNG they write,
  not only at test results.
- Live runs (`-live:N`) use the real account in `<state>/token`. Keep them read-only: don't type, send,
  react or join voice.
- Prefer the fewest lines where possible: no speculative API surface, delete dead paths.
- Formats from the network (images, compression, codecs) go through vetted libraries, not hand-written
  decoders: Wuffs first, else the reference C library or Odin's core library. Vendor upstream files
  unmodified in `vendor/<lib>/` with a small `fc_<lib>.c` wrapper and a README (URL, version, sha256,
  licence); `build.sh` / `build.bat` compile it. Hand-written code stays only where the library lacks a
  feature (animated WebP's container).
