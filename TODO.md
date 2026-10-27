# TODO

- [ ] Settings: keep every fastcord setting in one place so deleting them all is easy (may already be done).
- [ ] Accounts: support full account switching; today it assumes a single token.
- [ ] Voice: a speaking user's name should turn from grey to white, not only their avatar green.
- [ ] GIFs: some Klipy GIFs fail to load while Tenor ones work (seen on Windows).
- [ ] Replies: clicking the quoted original message should jump to it.
- [ ] Replies: the quoted preview line draws the original's text (a long Klipy/Tenor URL) over the author name instead of after it; it should start after the name and be truncated with an ellipsis.
- [ ] Replies: on a hovered reply, the quoted author name and URL draw through the hover toolbar (quick reactions and message options); the toolbar should cover them.
- [ ] Chat: welcome messages aren't shown properly.
- [ ] Member list: don't show the grey offline dot in a server's member sidebar, as the official client doesn't.
- [ ] Search: clicking the search bar again while results are open crashes.
- [ ] Scrolling: middle-click autoscroll, as in browsers on Windows: a middle click drops an anchor icon, then moving the mouse above or below it scrolls that way, faster the farther away; any click or Escape ends it.
- [ ] CI: turn the offline parity tests back on (the `Test` step in `.github/workflows/ci-build.yml` is `if: false`).
- [ ] CI: slim the Jai zip on the Fly server (drop `modules/Bindings_Generator`, ~360 MB of libclang) so each run downloads less.
- [ ] Crash reporter: add one, modelled on Happenlance's subprocess crash reporter (`C:\Work\Happenlance\Happenlance\src\crash_handler.cpp`, Phillip's machine only).
- [ ] Mentions: the "@" autocomplete lacks `@game` / `@time`, fuzzy matches and pills in the composer (`traffic/CLIENT_RULES.md` "Composer mentions").
- [ ] Events: clicking an event invite card should open the event's details modal (fastcord has none; it opens the Events list); event cards lack the cover image and recurring-event series picker.
- [ ] Sounds: check by ear on Windows and Linux that the UI sounds (now decoded by minimp3) play at the right pitch.
