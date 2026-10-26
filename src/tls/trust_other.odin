#+build !darwin
#+build !windows
package tls

// No OS trust store binding on this platform yet: fail closed.
verify_chain_os :: proc(chain: [][]byte, host: string) -> Error {
	return .Untrusted_Certificate
}
