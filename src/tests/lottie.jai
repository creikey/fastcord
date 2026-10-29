// Lottie check: jai build.jai - run src/tests/lottie.jai, then build/lottie. Hostile stickers (any server's)
// must load and render without crashing or hanging: NaN and huge sizes, self-referencing precomps,
// huge arrays, deep groups.
#import "Basic";
lottie :: #import "lottie";

failed := 0;

check :: (ok: bool, what: string) {
	if !ok { print("FAIL: %\n", what); failed += 1; }
}

// render loads doc and draws two frames at 64 px; it returns whether it loaded and the seconds taken.
render :: (doc: string) -> loaded: bool, seconds: float64 {
	t0 := seconds_since_init();
	anim := lottie.load(cast([]u8) doc);
	if !anim return false, seconds_since_init() - t0;
	defer lottie.destroy(anim);
	p: lottie.Player;
	lottie.player_init(*p, 64, 64);
	defer lottie.player_destroy(*p);
	lottie.render(*p, anim, 0);
	lottie.render(*p, anim, 0.5);
	return true, seconds_since_init() - t0;
}

repeat :: (s: string, n: int) -> string {
	sb: String_Builder;
	for 1..n append(*sb, s);
	return builder_to_string(*sb);
}

main :: () {
	rect :: #string JSON
{"ty":"gr","it":[{"ty":"rc","p":{"k":[%1,%1]},"s":{"k":[%2,%2]}},{"ty":"fl","c":{"k":[1,0,0,1]},"o":{"k":100}}]}
JSON
	shape :: (inner: string) -> string {
		return tprint("{\"w\":100,\"h\":100,\"fr\":30,\"ip\":0,\"op\":30,\"layers\":[{\"ty\":4,\"ks\":{},\"shapes\":[%]}]}", inner);
	}

	ok, _ := render(shape(tprint(rect, "50", "40")));
	check(ok, "a plain rectangle loads");

	for string.["\"w\":0,\"h\":0", "\"w\":1e30,\"h\":1e30", "\"w\":-5,\"h\":10", "\"w\":[[1e999]],\"h\":10"] {
		loaded := render(tprint("{%,\"layers\":[]}", it));
		check(!loaded, tprint("a sticker sized % is refused", it));
	}

	// sizes and positions that pass a naive clamp and cast to INT64_MIN
	for string.["1e30", "-1e30", "3e38", "1e-40"] {
		loaded, secs := render(shape(tprint(rect, it, it)));
		check(loaded && secs < 2, tprint("rectangle at % renders (% s)", it, secs));
	}
	loaded, secs := render(shape("{\"ty\":\"sr\",\"sy\":1,\"p\":{\"k\":[50,50]},\"pt\":{\"k\":1e30},\"or\":{\"k\":1e30},\"ir\":{\"k\":10}},{\"ty\":\"st\",\"c\":{\"k\":[0,0,0,1]},\"o\":{\"k\":100},\"w\":{\"k\":1e30}}"));
	check(loaded && secs < 2, tprint("huge star and stroke render (% s)", secs));

	// two precomp layers that each draw their own comp: 2^17 renders without a cap
	selfref :: #string JSON
{"w":64,"h":64,"fr":30,"ip":0,"op":30,"assets":[{"id":"a","layers":[{"ty":0,"refId":"a","ks":{}},{"ty":0,"refId":"a","ks":{}},{"ty":4,"ks":{},"shapes":[%1]}]}],"layers":[{"ty":0,"refId":"a","ks":{}}]}
JSON
	loaded, secs = render(tprint(selfref, tprint(rect, "10", "10")));
	check(loaded && secs < 2, tprint("self-referencing precomps render (% s)", secs));

	// empty shapes and masks, 3 bytes of JSON each: the file's size caps them
	many := repeat("{},", 170_000);
	loaded, secs = render(tprint("{\"w\":64,\"h\":64,\"layers\":[{\"ty\":4,\"ks\":{},\"shapes\":[%{}],\"masksProperties\":[%{}]}]}", many, many));
	check(loaded && secs < 5, tprint("340,000 shapes and masks load (% s)", secs));
	loaded = render(tprint("{\"w\":64,\"h\":64,\"layers\":[{\"ty\":4,\"ks\":{},\"shapes\":[%{}]}]}", repeat("{},", 400_000)));
	check(!loaded, "a file over 1 MB is refused");

	// many real shapes, each filled by many fills: the work per frame is capped
	loaded, secs = render(shape(tprint("%%{}", repeat(tprint("{\"ty\":\"rc\",\"p\":{\"k\":[32,32]},\"s\":{\"k\":[60,60]}},"), 2000), repeat("{\"ty\":\"fl\",\"c\":{\"k\":[1,0,0,1]},\"o\":{\"k\":100}},", 2000))));
	check(loaded && secs < 5, tprint("2000 rectangles under 2000 fills render (% s)", secs));

	// groups nested past the cap
	deep := tprint("%{}%", repeat("{\"ty\":\"gr\",\"it\":[", 55), repeat("]}", 55));
	loaded, secs = render(shape(deep));
	check(loaded && secs < 2, tprint("deep groups render (% s)", secs));

	if failed { print("lottie: % failed\n", failed); exit(1); }
	print("lottie: ok\n");
}
