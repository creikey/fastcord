import json, random, sys
# Deterministic Discord-gateway-like JSON events.
def words(r, n):
    W = "the quick brown fox jumps over lazy dog hello world lol yeah ok sure discord server channel message reaction emoji voice game play stream bot role admin mod gg wp nice cool what why how when lmao true false null".split()
    return " ".join(r.choice(W) for _ in range(n))
def snow(r): return str(r.randrange(10**17, 10**19))
def user(r):
    return {"id": snow(r), "username": "user%d" % r.randrange(100000), "global_name": words(r, 2).title(), "avatar": "%032x" % r.getrandbits(128), "discriminator": "0", "public_flags": r.choice([0, 64, 128, 256]), "avatar_decoration_data": None, "bot": r.random() < 0.05}
def msg(r, seq):
    t = r.random()
    if t < 0.6:
        d = {"type": 0, "tts": False, "timestamp": "2026-10-%02dT%02d:%02d:%02d.%06d+00:00" % (r.randrange(1,28), r.randrange(24), r.randrange(60), r.randrange(60), r.randrange(10**6)),
             "pinned": False, "mentions": [user(r) for _ in range(r.randrange(3))], "mention_roles": [], "mention_everyone": False, "id": snow(r), "flags": 0,
             "embeds": [], "edited_timestamp": None, "content": words(r, r.randrange(1, 60)), "components": [], "channel_id": snow(r), "author": user(r),
             "attachments": [], "guild_id": snow(r), "nonce": snow(r), "member": {"roles": [snow(r) for _ in range(r.randrange(5))], "premium_since": None, "pending": False, "nick": None, "mute": False, "joined_at": "2024-01-01T00:00:00.000000+00:00", "flags": 0, "deaf": False, "communication_disabled_until": None, "banner": None, "avatar": None}}
        return {"t": "MESSAGE_CREATE", "s": seq, "op": 0, "d": d}
    if t < 0.8:
        return {"t": "TYPING_START", "s": seq, "op": 0, "d": {"user_id": snow(r), "timestamp": r.randrange(1700000000, 1800000000), "channel_id": snow(r), "guild_id": snow(r)}}
    if t < 0.95:
        return {"t": "PRESENCE_UPDATE", "s": seq, "op": 0, "d": {"user": {"id": snow(r)}, "status": r.choice(["online", "idle", "dnd", "offline"]), "client_status": {"desktop": "online"}, "activities": [{"type": 0, "name": words(r, 3), "created_at": r.randrange(10**12, 2*10**12), "id": "%016x" % r.getrandbits(64)} for _ in range(r.randrange(3))], "guild_id": snow(r)}}
    # big guild member chunk
    return {"t": "GUILD_MEMBERS_CHUNK", "s": seq, "op": 0, "d": {"guild_id": snow(r), "members": [{"user": user(r), "roles": [snow(r) for _ in range(r.randrange(4))], "nick": None, "joined_at": "2024-01-01T00:00:00.000000+00:00"} for _ in range(r.randrange(10, 120))]}}
def gen(seed, n):
    r = random.Random(seed)
    return [json.dumps(msg(r, i + 1), separators=(",", ":")).encode() for i in range(n)]
if __name__ == "__main__":
    mode, out, seed, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    if mode == "blob":  # one JSON array of events of ~size bytes
        r = random.Random(seed); parts = []; tot = 0; i = 0
        while tot < size:
            m = json.dumps(msg(r, i), separators=(",", ":")).encode(); parts.append(m); tot += len(m) + 1; i += 1
        open(out, "wb").write(b"[" + b",".join(parts) + b"]")
    else:  # length-prefixed messages for the gateway generator
        with open(out, "wb") as f:
            for m in gen(seed, size):
                f.write(len(m).to_bytes(4, "little")); f.write(m)
