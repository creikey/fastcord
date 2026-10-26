// Extracts every icon of the official client's design-system icon namespace
// (the object whose exports are FriendsIcon, GifIcon, ...) as standalone SVG.
// Read-only: walks webpack module sources, evaluates each icon component in a
// sandbox with a fake jsx runtime, serializes the returned element tree.
// Also grabs a few DOM-only SVGs (status masks, typing dots, home logo).
// Returns JSON: {icons: {Name: {svg, multicolor}}, dom: {name: svg}, errors: [...]}
(() => {
	let reqs = [];
	window.webpackChunkdiscord_app.push([[Symbol()], {}, r => { reqs.push(r); }]);
	window.webpackChunkdiscord_app.pop();
	const req = reqs.find(r => Object.keys(r.c || {}).length > 1000) || reqs[0];

	let entryId = null;
	for (const id of Object.keys(req.m)) {
		const s = req.m[id].toString();
		if (s.includes("FriendsIcon:()=>") && s.includes("GifIcon:()=>")) { entryId = id; break; }
	}
	const entry = req.m[entryId].toString();

	// Export map {Name:()=>ref}.
	const balanced = (s, open) => {
		let depth = 0;
		for (let i = open; i < s.length; i++) {
			const c = s[i];
			if (c === '"' || c === "'" || c === "`") { // skip strings
				for (i++; i < s.length && s[i] !== c; i++) if (s[i] === "\\") i++;
				continue;
			}
			if (c === "{") depth++;
			else if (c === "}") { depth--; if (!depth) return i; }
		}
		return -1;
	};
	const mapAt = entry.indexOf("FriendsIcon:()=>");
	const mapStart = entry.lastIndexOf("{", entry.lastIndexOf(",{", mapAt) + 1);
	const mapBody = entry.slice(mapStart + 1, balanced(entry, mapStart));
	const ents = mapBody.split(",").map(x => x.split(":()=>")).filter(x => x.length === 2 && /Icon$/.test(x[0]));

	// Locate function source for a ref.
	const esc = s => s.replace(/[$]/g, "\\$");
	const fnSrcIn = (src, name) => {
		let m = new RegExp("function " + esc(name) + "\\(").exec(src);
		if (m) { const b = src.indexOf("{", m.index); return src.slice(m.index, balanced(src, b) + 1); }
		m = new RegExp("[,;{ ]" + esc(name) + "=(\\(?[\\w$]*\\)?=>)").exec(src);
		if (m) {
			const b = src.indexOf("{", m.index + m[0].length - 1);
			return "(" + m[1] + src.slice(b, balanced(src, b) + 1) + ")";
		}
		return null;
	};
	const resolve = ref => {
		if (!ref.includes(".")) return fnSrcIn(entry, ref);
		const [mv, key] = ref.split(".");
		const m = new RegExp("[,; ]" + esc(mv) + "=n\\((\\d+)\\)").exec(entry);
		if (!m) return null;
		const ms = req.m[m[1]].toString();
		const em = new RegExp("[{,]" + esc(key) + ":\\(\\)=>([\\w$]+)").exec(ms);
		if (!em) return null;
		return fnSrcIn(ms, em[1]);
	};

	// Sandbox: any free name resolves to a stub; jsx calls are rewritten.
	const stub = new Proxy(function () {}, {
		get: (t, k) => k === Symbol.toPrimitive ? () => "" : stub,
		apply: () => undefined,
	});
	const scope = new Proxy({}, {
		has: (t, k) => k !== "__jsx" && k !== "Object" && k !== "Array" && k !== "Math" && k !== "String",
		get: (t, k) => k === Symbol.unscopables ? undefined : stub,
	});
	const SECONDARY = "__secondary__";
	const mk = (type, props) => ({ type, props: props || {} });
	const keepCamel = new Set(["viewBox", "preserveAspectRatio", "maskUnits", "maskContentUnits", "clipPathUnits",
		"gradientUnits", "gradientTransform", "patternUnits", "patternTransform", "stdDeviation", "pathLength"]);
	const drop = new Set(["className", "children", "xmlns", "style", "ref", "key"]);
	const attrName = (k, tag) => drop.has(k) || (tag === "svg" && (k === "width" || k === "height")) ? null : k === "xlinkHref" ? "href" : keepCamel.has(k) ? k
		: k.replace(/[A-Z]/g, c => "-" + c.toLowerCase());
	const ser = (el, colors) => {
		if (el == null || el === false) return "";
		if (Array.isArray(el)) return el.map(e => ser(e, colors)).join("");
		if (typeof el !== "object") return "";
		if (typeof el.type !== "string") return ser(el.props.children, colors); // fragments
		let a = "";
		for (const [k, v] of Object.entries(el.props)) {
			if (k.startsWith("aria") || k === "role" || k === "focusable") continue;
			const n = attrName(k, el.type);
			if (n === null || v == null || typeof v === "object" || typeof v === "function") continue;
			if ((n === "fill" || n === "stroke" || n === "stop-color") && v !== "none" && v !== SECONDARY) colors.add(String(v));
			if (v === SECONDARY) colors.add("secondary");
			if (v === SECONDARY) { a += ` fill="currentColor" class="secondary"`; continue; }
			a += ` ${n}="${String(v).replace(/"/g, "&quot;")}"`;
		}
		const tag = el.type;
		const kids = ser(el.props.children, colors);
		if (tag === "svg") return `<svg xmlns="http://www.w3.org/2000/svg"${a}>${kids}</svg>`;
		return kids ? `<${tag}${a}>${kids}</${tag}>` : `<${tag}${a}/>`;
	};

	const icons = {}, errors = [];
	for (const [name, ref] of ents) {
		try {
			let src = resolve(ref);
			if (!src) { errors.push(name + ": no source " + ref); continue; }
			src = src.replace(/\(0,[\w$]+\.jsxs?\)/g, " __jsx ");
			const fn = new Function("__scope", "__jsx", "with(__scope){return (" + src + ")}")(scope, mk);
			const el = fn({ color: "currentColor", secondaryColor: SECONDARY, size: "custom", width: 24, height: 24 });
			const colors = new Set();
			const svg = ser(el, colors);
			if (!svg.startsWith("<svg")) { errors.push(name + ": bad tree"); continue; }
			colors.delete("currentColor");
			icons[name] = { svg, multicolor: [...colors] };
		} catch (e) { errors.push(name + ": " + e); }
	}

	// DOM-only SVGs. Avatar/status masks become renderable shapes: a unit rect
	// painted through the mask (white = keep, black = cut).
	const dom = {};
	for (const m of document.querySelectorAll("mask[id^='svg-mask-']")) {
		const name = m.id.replace("svg-mask-", "");
		const units = m.getAttribute("maskContentUnits") === "objectBoundingBox";
		const vb = units ? "0 0 1 1" : (m.closest("svg").getAttribute("viewBox") || "0 0 1 1");
		const inner = [...m.children].map(c => c.outerHTML.replace(/ class="[^"]*"/g, "")).join("");
		const [, , w, h] = vb.split(" ");
		dom[name] = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}"><mask id="m" maskUnits="userSpaceOnUse" x="0" y="0" width="${w}" height="${h}">${inner}</mask><rect x="0" y="0" width="${w}" height="${h}" fill="currentColor" mask="url(#m)"/></svg>`;
	}
	// Guild icon squircle ("blob") shape from the server rail, 40x40.
	const blob = document.querySelector("nav[aria-label='Servers sidebar'] svg defs path");
	if (blob) dom["guild-blob"] = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><path fill="currentColor" d="${blob.getAttribute("d")}"/></svg>`;
	// Typing indicator (module with dotCycle): dotRadius 3.5, spacing 2.5 → cx = r + r*2.5*i,
	// svg 24.5x7. Animated: per dot phase .25, r .8r..r and opacity .3..1 over 2400ms.
	const tr = 3.5;
	dom["typing-dots"] = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${2 * tr * 3 + tr} ${2 * tr}">` +
		[0, 1, 2].map(i => `<circle fill="currentColor" cx="${tr + tr * 2.5 * i}" cy="${tr}" r="${tr}"/>`).join("") + `</svg>`;

	return JSON.stringify({ entryId, count: ents.length, icons, dom, errors });
})()
