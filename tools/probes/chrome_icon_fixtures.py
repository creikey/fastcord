# Renders SVGs with the official client's Chrome (offscreen canvas drawImage) and
# saves the alpha channel as raw A8 fixtures for src/vector's comparison test.
#   python3 -I tools/probes/chrome_icon_fixtures.py [PORT]
# Read-only: Runtime.evaluate on the page target; no network, no UI changes.
import base64, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
TD = os.path.join(ROOT, "src", "vector", "testdata")
sys.path.insert(0, HERE)
from discord_icons import evaluate  # noqa: E402

ICONS = ["friends", "compass", "settings", "microphone-slash", "headphones-slash", "hashmark", "text",
         "voice-normal", "announcements", "thread", "forum", "at", "gif", "sticker", "gift", "circle-plus",
         "magnifying-glass", "pin", "inbox", "clyde", "nitro-wheel", "status-idle", "status-dnd",
         "status-online-mobile", "status-online-vr", "mask-avatar-status-round-32", "typing-dots", "x-large",
         "chevron-small-down", "more-horizontal", "reaction", "arrow-angle-left-up", "pencil", "circle-x",
         "emoji-grinning-face", "shop", "quests", "plus-large", "user-plus", "guild-blob"]
EXTRA = ["stroke_shapes", "misc_shapes"]

# Each SVG is drawn twice: directly at 48px (Chrome/Skia AA as the client shows it),
# and at 16x / 8x then box-filtered down to 24 / 48 px ("ss": near exact-area
# ground truth for Chrome's geometry, independent of Skia's AA approximations).
JS = r"""
(async (items) => {
	const draw = async (src, px) => {
		const svg = src.replace(/<svg /, `<svg width="${px}" height="${px}" `);
		const url = URL.createObjectURL(new Blob([svg], {type: "image/svg+xml"}));
		const img = new Image(); img.src = url; await img.decode();
		const c = new OffscreenCanvas(px, px), g = c.getContext("2d");
		g.drawImage(img, 0, 0); URL.revokeObjectURL(url);
		const d = g.getImageData(0, 0, px, px).data, a = new Float64Array(px * px);
		for (let i = 0; i < a.length; i++) a[i] = d[i * 4 + 3];
		return a;
	};
	const down = (a, px, f) => {
		const n = px / f, o = new Uint8Array(n * n);
		for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
			let s = 0;
			for (let j = 0; j < f; j++) for (let i = 0; i < f; i++) s += a[(y * f + j) * px + x * f + i];
			o[y * n + x] = Math.round(s / (f * f));
		}
		return o;
	};
	const b64 = a => { let s = ""; for (const v of a) s += String.fromCharCode(v); return btoa(s); };
	const out = {};
	for (const [name, src] of items) {
		out[name + "_48"] = b64(Uint8Array.from(await draw(src, 48)));
		const big = await draw(src, 384);
		out[name + "_ss48"] = b64(down(big, 384, 8));
		out[name + "_ss24"] = b64(down(big, 384, 16));
	}
	return JSON.stringify(out);
})
"""


def main():
	port = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
	items = [[n, open(os.path.join(ROOT, "assets", "icons", n + ".svg")).read().strip()] for n in ICONS]
	items += [[n, open(os.path.join(TD, n + ".svg")).read().strip()] for n in EXTRA]
	res = json.loads(evaluate(port, JS + f"({json.dumps(items)})"))
	os.makedirs(os.path.join(TD, "chrome"), exist_ok=True)
	for k, v in res.items():
		open(os.path.join(TD, "chrome", k + ".a8"), "wb").write(base64.b64decode(v))
	print(f"wrote {len(res)} fixtures")


main()
