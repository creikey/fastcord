// The UI sweep's change hash: FNV-1a stands in for XXH3 (only equality matters).
h :: #import "fc_hash";
XXH3_64 :: (data: []u8) -> u64 { return h.fnv64a(data); }
