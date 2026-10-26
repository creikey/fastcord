#!/usr/bin/env python3
# extract_emoji.py <web.*.js> <vnd-emoji.*.js> <out.json>
#
# Builds assets/emoji/emoji.json from the official client's JS bundle (offline;
# no CDP). Sources inside the bundle:
#   vnd-emoji chunk, module 13474: JSON.parse('{"emojis":[...],"emojisByCategory":...}')
#     -> names (first = canonical shortcode, rest = aliases), surrogates,
#        unicodeVersion, spriteIndex, diversity (skin tone) parents/children.
#   web chunk: webpack context module 874629 {"./<codepoints>.svg": "<module id>"}
#   vnd-emoji chunk: <module id>(e){e.exports="/assets/<hash>.svg"}
#   Client URL rule (module 350593, getURL): ™ © ® have no image; otherwise if the
#   text has no ZWJ (U+200D) the *first* U+FE0F is removed, then twemoji
#   toCodePoint (lowercase hex code points joined by "-") -> "./<cp>.svg".
#   Default frecency seeds (used when the user has no history) are static arrays
#   in the web chunk.
import json, re, sys

web = open(sys.argv[1], encoding='utf-8').read()
vnd = open(sys.argv[2], encoding='utf-8').read()

m = re.search(r"13474\(e\)\{e\.exports=JSON\.parse\('(.*?)'\)\}", vnd, re.S)
raw = m.group(1).replace("\\'", "'")
# The literal is a JS single-quoted string holding JSON: decode JS escapes, then JSON.
data = json.loads(raw.encode('latin-1', 'backslashreplace').decode('unicode_escape').encode('utf-16', 'surrogatepass').decode('utf-16'))

ctx = re.search(r'\{("\./[0-9a-f-]+\.svg":"\d+",?)+\}', web).group(0)
svg_ctx = json.loads(ctx)
# module ids are minified: 358000 is written as 358e3
mod_url = {}
for src in (vnd, web):
    for mid, url in re.findall(r'(\d+(?:e\d+)?)\(e\)\{(?:"use strict";)?e\.exports="(/assets/[0-9a-f]+\.svg)"\}', src):
        mod_url[str(int(float(mid)))] = url

NO_IMAGE = {"™", "™️", "\xa9", "\xa9️", "\xae", "\xae️"}
def url_for(s):
    if s in NO_IMAGE: return ""
    t = s.replace("️", "", 1) if "‍" not in s else s
    key = "./" + "-".join("%x" % ord(c) for c in t) + ".svg"
    mid = svg_ctx.get(key)
    return mod_url.get(mid, "") if mid else ""

emojis = []
missing = 0
for e in data["emojis"]:
    o = {"n": e["names"], "s": e["surrogates"], "v": e.get("unicodeVersion")}
    u = url_for(e["surrogates"])
    if not u and e["surrogates"] not in NO_IMAGE: missing += 1
    o["u"] = u[len("/assets/"):-len(".svg")] if u else ""
    if "spriteIndex" in e: o["sp"] = e["spriteIndex"]
    if "diversityChildren" in e: o["dc"] = e["diversityChildren"]
    if "diversity" in e: o["d"] = e["diversity"]
    if e.get("hasMultiDiversity"): o["md"] = 1
    emojis.append(o)

out = {
    "_doc": "Discord unicode emoji DB extracted from the client bundle by tools/probes/extract_emoji.py. "
            "emojis[i]: n=names (n[0] canonical shortcode, rest aliases), s=surrogates, v=unicodeVersion, "
            "u=Twemoji asset hash -> https://discord.com/assets/<u>.svg (empty: no image), sp=spriteIndex, "
            "dc=skin-tone children indices (tone1..5, or 25 for multi-person md=1), d=skin tone code points of a child. "
            "categories: picker order, [start, end) index ranges into emojis (children follow index 1932+). "
            "Search in the client matches names only (no separate keyword table).",
    "asset_url": "https://discord.com/assets/{u}.svg",
    "categories": [[k, v[0], v[1]] for k, v in data["emojisByCategory"].items()],
    "default_frecency": [],
    "default_reaction_frecency": [],
    "emojis": emojis,
}
m = re.findall(r'for\(let e of(\["[^\]]*\])\)e\w\.track\(e\)', web)
if len(m) >= 2:
    out["default_frecency"] = json.loads(m[0])
    out["default_reaction_frecency"] = json.loads(m[1])
json.dump(out, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
print(len(emojis), "emojis,", missing, "without asset,", len(svg_ctx), "svg modules")
