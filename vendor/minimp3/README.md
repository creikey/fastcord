# minimp3

MP3 decoding on Windows and Linux (macOS decodes MP3 with AudioToolbox), for the UI sounds
(`discord.com/assets/<hash>.mp3`) and MP3 attachments. `minimp3.h` is upstream's header, unmodified:

- Source: https://github.com/lieff/minimp3, `minimp3.h` at commit afb604c06bc8beb145fecd42c0ceb5bda8795144
- sha256: 5fb296a790734772b65a5514438cc06d14f24e539c13475ff2a7f737681c82c0
- Licence: CC0 1.0 (LICENSE)

Why minimp3: the decoder the common single-file libraries (dr_mp3, Raylib) build on, fuzzed, no
allocation, conformance-tested against the ISO reference vectors. Wuffs has no MP3 decoder.

`fc_minimp3.c` is ours: the implementation with float output and three plain calls where the caller owns
the decoder state. `build.jai` compiles it into `build/fc_vendor.a`.
