// verify collects every secret the raw capture contains (auth tokens, cookie
// values, identify token, emails, phones, fingerprints, installation ids,
// analytics/session tokens) and reports any that appear in the fixture text.
// Reports name the kind and location only, never the value.
verify :: (raw: string, fixture: string) -> []string {
	secrets := Map(string, string).{}; // value -> kind
	for l: strings.split_lines(raw, temp) {
		if len(l) == 0 { continue; }
		v, err := etf.from_json(l, temp);
		if err != .None { continue; }
		collect_secrets(v, "", *secrets);
		{ b := gs(v, "m", "result", "body");
		if len(b) > 0 && len(b) < (8 << 20) {
			{ bv, berr := etf.from_json(b, temp);
			if berr == .None { collect_secrets(bv, "", *secrets); } }
		} }
		// token-shaped strings anywhere in raw
		for i: 0..len(l)-1 {
			{ n := token_at(l, i);
			if n > 0 { at(*secrets, clone(sub(l, i, i + n))).* = "token-pattern"; } }
		}
	}
	problems := make_dynamic(string, 0, 0);
	for val, kind: secrets {
		if len(val) < 8 { continue; }
		{ at := strings.index(fixture, val);
		if at >= 0 {
			// context before the value, never the value itself
			ctx := sub(fixture, max(at - 60, 0), at);
			append(*problems, fmt.aprintf("%s value (len %d) survives in fixture after %q", kind, len(val), ctx));
		} }
	}
	for i: 0..len(fixture)-1 {
		{ n := token_at(fixture, i);
		if n > 0 {
			append(*problems, fmt.aprintf("token-shaped string at byte %d", i));
			break;
		} }
	}
	return view(problems);
}
#scope_module

SECRET_KEYS := string.[
	"token", "authorization", "email", "phone", "analytics_token", "fingerprint", "installation_id",
	"session_id", "auth_session_id_hash", "x-fingerprint", "x-installation-id", "password", "captcha_key", "ticket"
];

collect_secrets :: (v: etf.Value, key: string, out: *Map(string, string)) {
	lkey := strings.to_lower(key, temp);
	if v.kind == {
	case .String; x := v.s;
		for k: SECRET_KEYS {
			if lkey == k && len(x) >= 8 { at(out, clone(x)).* = clone(k); }
		}
		if lkey == "cookie" || lkey == "set-cookie" {
			for line: strings.split(x, "\n", temp) {
				for part, pi: strings.split(line, ";", temp) {
					// set-cookie: only the first pair is a cookie; the rest are attributes
					if lkey == "set-cookie" && pi > 0 { break; }
					eq := strings.index_byte(part, #char "=");
					if eq > 0 {
						val := strings.trim_space(sub_from(part, eq + 1));
						if len(val) >= 8 { at(out, clone(val)).* = "cookie"; }
					}
				}
			}
		}
		if strings.contains(x, "@") {
			for i: 0..len(x)-1 {
				if x[i] == #char "@" {
					{ st, en, ok := email_span(x, i);
					if ok && en - st >= 6 { at(out, clone(sub(x, st, en))).* = "email"; } }
				}
			}
		}
	case .List; x := v.list;
		for e: x { collect_secrets(e, key, out); }
	case .Map; x := v.map;
		for p: x {
			k := vs(p.key);
			collect_secrets(p.value, k, out);
		}
	}
}
#scope_export

