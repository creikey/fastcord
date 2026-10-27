#import "Basic";
#import "fc";
fnv64a :: (data: []u8, seed: u64 = 0xcbf29ce484222325) -> u64 {
    h := seed;
    for data { h ^= it; h *= 0x100000001b3; }
    return h;
}
crc32 :: (data: []u8, seed: u32 = 0) -> u32 {
    TABLE :: #run -> [256]u32 {
        t: [256]u32;
        for i: 0..255 { c := cast(u32) i; for 1..8 c = ifx c & 1 then 0xEDB88320 ^ (c >> 1) else c >> 1; t[i] = c; }
        return t;
    };
    c := ~seed;
    for data c = TABLE[(c ^ it) & 0xFF] ^ (c >> 8);
    return ~c;
}
adler32 :: (data: []u8, seed: u32 = 1) -> u32 {
    a, b := seed & 0xFFFF, seed >> 16;
    for data { a = (a + it) % 65521; b = (b + a) % 65521; }
    return (b << 16) | a;
}
