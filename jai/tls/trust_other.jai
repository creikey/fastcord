// No OS trust store binding on this platform yet: fail closed.
verify_chain_os :: (chain: [][]u8, host: string) -> Error { return .Untrusted_Certificate; }
