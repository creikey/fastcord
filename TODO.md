# TODO

- [ ] Settings: keep every fastcord setting in one place so deleting them all is easy (may already be done).
- [ ] Accounts: support full account switching; today it assumes a single token.
- [ ] Voice: a speaking user's name should turn from grey to white, not only their avatar green.
- [ ] GIFs: some Klipy GIFs fail to load while Tenor ones work (seen on Windows).
- [ ] Replies: clicking the quoted original message should jump to it.
- [ ] Chat: welcome messages aren't shown properly.
- [ ] Member list: don't show the grey offline dot in a server's member sidebar, as the official client doesn't.
- [ ] Search: clicking the search bar again while results are open crashes.
- [ ] CI: turn the offline parity tests back on (the `Test` step in `.github/workflows/ci-build.yml` is `if: false`).
- [ ] CI: slim the Jai zip on the Fly server (drop `modules/Bindings_Generator`, ~360 MB of libclang) so each run downloads less.
- [ ] Crash reporter: add one, modelled on Happenlance's subprocess crash reporter (`C:\Work\Happenlance\Happenlance\src\crash_handler.cpp`, Phillip's machine only).
