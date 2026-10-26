package app

import "core:os"
import "core:testing"

@(test)
test_version_newer :: proc(t: ^testing.T) {
	testing.expect(t, version_newer("v0.2.0", "v0.1.9"))
	testing.expect(t, version_newer("v1.0", "v0.9.9"))
	testing.expect(t, version_newer("v0.10.0", "v0.9.0"))
	testing.expect(t, !version_newer("v0.1.0", "v0.1.0"))
	testing.expect(t, !version_newer("v0.1.0", "v0.2.0"))
	testing.expect(t, version_newer("0.3", "v0.2.5"))
}

// FASTCORD_LIVE=1: the release check works end to end through our TLS/HTTP stack.
@(test)
test_fetch_latest_tag_live :: proc(t: ^testing.T) {
	if os.get_env("FASTCORD_LIVE", context.temp_allocator) == "" do return
	tag, ok := fetch_latest_tag("odin-lang/Odin")
	defer delete(tag)
	testing.expect(t, ok)
	testing.expect(t, len(tag) > 0)
}
