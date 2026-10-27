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
  is shaped like a real account (`tests/bench/shape.json`); `tools/bench.sh --live` checks that it still
  matches, read-only.
- Headless runs (`-shot:`, `-bench`) render offscreen. Check UI changes by looking at the PNG they write,
  not only at test results.
- Live runs (`-live:N`) use the real account in `<state>/token`. Keep them read-only: don't type, send,
  react or join voice.
- Behaviour copied from the official client's code (bundle, stores, action creators), or inferred or
  guessed without a capture, goes in `traffic/CLIENT_RULES.md` in the same change: rule, kind, the
  anchor to search for in the bundle, and where fastcord implements it. It is reviewed on every
  Discord update.
