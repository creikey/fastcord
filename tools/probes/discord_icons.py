# Dumps the official client's icons to assets/icons/*.svg + index.json.
#   python3 -I tools/probes/discord_icons.py [PORT]   (default 9333, the test client's DevTools)
# Read-only: one Runtime.evaluate of tools/probes/discord_icons.js on the page target.
import base64, json, os, re, socket, struct, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "assets", "icons")


def evaluate(port, expr):
	tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
	page = [t for t in tabs if t["type"] == "page"][0]
	host, path = page["webSocketDebuggerUrl"][5:].split("/", 1)
	h, p = host.split(":")
	s = socket.create_connection((h, int(p)))
	key = base64.b64encode(os.urandom(16)).decode()
	s.sendall(f"GET /{path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
	          f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
	buf = b""
	while b"\r\n\r\n" not in buf:
		buf += s.recv(4096)
	buf = buf.split(b"\r\n\r\n", 1)[1]
	data = json.dumps({"id": 1, "method": "Runtime.evaluate",
	                   "params": {"expression": expr, "returnByValue": True, "awaitPromise": True}}).encode()
	mask = os.urandom(4)
	n = len(data)
	hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
	                       bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else
	                       bytes([0x80 | 127]) + struct.pack(">Q", n))
	s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

	def need(k):
		nonlocal buf
		while len(buf) < k:
			buf += s.recv(1 << 16)
		r, buf = buf[:k], buf[k:]
		return r

	while True:
		msg = b""
		while True:
			hh = need(2)
			ln = hh[1] & 127
			if ln == 126: ln = struct.unpack(">H", need(2))[0]
			elif ln == 127: ln = struct.unpack(">Q", need(8))[0]
			msg += need(ln)
			if hh[0] & 0x80: break
		m = json.loads(msg)
		if m.get("id") == 1:
			return m["result"]["result"]["value"]


# Where the official client uses each icon. "dom" = confirmed by matching path data
# of the live UI's <svg>s against assets/icons; "name" = chosen by component name.
# Lottie-animated buttons (mute, deafen, user settings, gift, gif, sticker, apps)
# rest on frames equal to the static icon listed.
UI = {
	"home-logo": ("clyde", "dom"), "guild-icon-shape": ("guild-blob", "dom"),
	"add-server": ("circle-plus", "dom"), "discover": ("compass", "dom"),
	"inbox": ("inbox", "dom"), "help": ("circle-question", "dom"),
	"nav-back": ("arrow-small-left", "dom"), "nav-forward": ("arrow-small-right", "dom"),
	"friends": ("friends", "name"), "nitro": ("nitro-wheel", "dom"), "shop": ("shop", "name"),
	"quests": ("quests", "name"), "dm-create": ("plus-small", "name"),
	"server-menu-chevron": ("chevron-small-down", "dom"), "category-arrow": ("chevron-small-down", "dom"),
	"invite-to-server": ("group-plus", "dom"), "create-channel": ("plus-medium", "dom"),
	"channel-text": ("text", "dom"), "channel-voice": ("voice-normal", "dom"),
	"channel-announcement": ("announcements", "name"), "channel-rules": ("book-check", "name"),
	"channel-thread": ("thread", "dom"), "channel-forum": ("forum", "name"), "channel-stage": ("stage", "name"),
	"channel-invite": ("user-plus", "dom"), "channel-settings": ("settings", "dom"), "channel-open-chat": ("chat", "dom"),
	"events": ("calendar", "dom"), "server-boosts": ("boost-gem", "dom"),
	"mic": ("microphone", "name"), "mic-muted": ("microphone-slash", "name"),
	"headphones": ("headphones", "name"), "deafened": ("headphones-slash", "name"),
	"user-settings": ("settings", "name"), "device-options-chevron": ("chevron-small-down", "dom"),
	"header-threads": ("thread", "dom"), "header-notifications": ("bell", "dom"), "header-pins": ("pin", "dom"),
	"header-members": ("group", "dom"), "search": ("magnifying-glass", "dom"), "search-clear": ("x-small", "dom"),
	"message-react": ("reaction", "dom"), "message-edit": ("pencil", "dom"), "message-forward": ("arrow-angle-right-up", "dom"),
	"message-more": ("more-horizontal", "dom"), "message-reply": ("arrow-angle-left-up", "name"),
	"chat-upload": ("plus-large", "dom"), "chat-gift": ("gift", "name"), "chat-gif": ("gif", "name"),
	"chat-sticker": ("sticker", "name"), "chat-apps": ("apps", "name"), "chat-emoji": ("emoji-grinning-face", "name"),
	"modal-close": ("x-large", "dom"), "mention": ("at", "name"), "typing": ("typing-dots", "dom"),
	"status-online": ("status-online", "dom"), "status-idle": ("status-idle", "dom"), "status-dnd": ("status-dnd", "dom"),
	"status-offline": ("status-offline", "dom"), "status-mobile": ("status-online-mobile", "dom"),
	"status-streaming": ("status-streaming", "dom"),
}


def kebab(name):
	name = re.sub(r"Icon$", "", name)
	name = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", name)
	name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", name)
	return name.lower()


def main():
	port = int(sys.argv[1]) if len(sys.argv) > 1 else 9333
	src = open(os.path.join(HERE, "discord_icons.js")).read()
	d = json.loads(evaluate(port, src))
	if d["errors"]:
		print("errors:", *d["errors"], sep="\n  ", file=sys.stderr)
	os.makedirs(OUT, exist_ok=True)
	index = {}

	def put(name, svg, **meta):
		assert name not in index, name
		open(os.path.join(OUT, name + ".svg"), "w").write(svg + "\n")
		vb = re.search(r'viewBox="([^"]+)"', svg).group(1)
		index[name] = {"file": name + ".svg", "viewBox": vb, **meta}

	for comp, ic in sorted(d["icons"].items()):
		meta = {"source": "design-system", "component": comp}
		colors = [c for c in ic["multicolor"] if c != "secondary"]
		if "secondary" in ic["multicolor"]: meta["secondary"] = True  # shapes with class="secondary"
		if colors: meta["colors"] = colors  # fixed brand colors: not a single-color icon
		if 'stroke="' in ic["svg"]: meta["stroked"] = True
		put(kebab(comp), ic["svg"], **meta)
	for name, svg in sorted(d["dom"].items()):
		meta = {"source": "dom"}
		if name == "typing-dots":
			meta["note"] = "animated: dot i phase .25*i, r 0.8r..r, opacity .3..1, 2400ms cycle"
		elif name.startswith("status-"):
			meta["note"] = "status indicator shape (mask svg-mask-" + name + ")"
		elif name != "guild-blob":
			meta["note"] = "avatar/clip mask svg-mask-" + name
			name = "mask-" + name
		put(name, svg, **meta)
	for role, (name, how) in UI.items():
		assert name in index, name
	ui = {role: {"icon": name, "verified": how} for role, (name, how) in UI.items()}
	json.dump({"icons": index, "ui": ui}, open(os.path.join(OUT, "index.json"), "w"), indent=1, sort_keys=True)
	print(f"wrote {len(index)} icons to {OUT}")


if __name__ == "__main__":
	main()
