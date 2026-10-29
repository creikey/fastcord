# Security

Please report security holes privately, not in a public issue.

## How to report

Use **Report a vulnerability** on the repository's Security tab
(<https://github.com/creikey/fastcord/security/advisories/new>). Include what you found, how to
reproduce it (a crafted file, message or packet helps), and which version or commit you tested.

## In scope

- End-to-end encrypted DMs (`src/e2e`, `src/keys`): reading, forging or replaying messages, key
  substitution, anything that leaks plaintext or keys.
- `fastcord -serve` (`src/serve`): crashing, freezing or taking over a server, reading what a
  member shouldn't, bypassing roles, bans or invites.
- Anything a server, Discord included, or another user can send that crashes fastcord, corrupts
  memory, runs code, or reveals your token, keys, files or IP address: parsers, media and image
  decoders, Lottie stickers, links, the updater.

Bugs in Discord itself, and attacks needing control of your own machine, are out of scope.

## What happens next

You'll get an answer within a week. A fix ships as a patch release first; the advisory is published
after it, crediting you unless you'd rather not be named.
