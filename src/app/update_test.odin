package app

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
