package scrub

import "core:fmt"
import "core:strings"
import "fc:etf"

// verify collects every secret the raw capture contains (auth tokens, cookie
// values, identify token, emails, phones, fingerprints, installation ids,
// analytics/session tokens) and reports any that appear in the fixture text.
// Reports name the kind and location only, never the value.
verify :: proc(raw: string, fixture: string) -> []string {
	secrets := make(map[string]string) // value -> kind
	for l in strings.split_lines(raw, context.temp_allocator) {
		if len(l) == 0 do continue
		v, err := etf.from_json(l, context.temp_allocator)
		if err != .None do continue
		collect_secrets(v, "", &secrets)
		if b := gs(v, "m", "result", "body"); len(b) > 0 && len(b) < 8 << 20 {
			if bv, berr := etf.from_json(b, context.temp_allocator); berr == .None do collect_secrets(bv, "", &secrets)
		}
		// token-shaped strings anywhere in raw
		for i in 0 ..< len(l) {
			if n := token_at(l, i); n > 0 do secrets[strings.clone(l[i:i + n])] = "token-pattern"
		}
	}
	problems := make([dynamic]string)
	for val, kind in secrets {
		if len(val) < 8 do continue
		if at := strings.index(fixture, val); at >= 0 {
			// context before the value, never the value itself
			ctx := fixture[max(at - 60, 0):at]
			append(&problems, fmt.aprintf("%s value (len %d) survives in fixture after %q", kind, len(val), ctx))
		}
	}
	for i in 0 ..< len(fixture) {
		if n := token_at(fixture, i); n > 0 {
			append(&problems, fmt.aprintf("token-shaped string at byte %d", i))
			break
		}
	}
	return problems[:]
}

@(private)
SECRET_KEYS := [?]string {
	"token", "authorization", "email", "phone", "analytics_token", "fingerprint", "installation_id",
	"session_id", "auth_session_id_hash", "x-fingerprint", "x-installation-id", "password", "captcha_key", "ticket",
}

@(private)
collect_secrets :: proc(v: etf.Value, key: string, out: ^map[string]string) {
	lkey := strings.to_lower(key, context.temp_allocator)
	#partial switch x in v {
	case string:
		for k in SECRET_KEYS {
			if lkey == k && len(x) >= 8 do out[strings.clone(x)] = strings.clone(k)
		}
		if lkey == "cookie" || lkey == "set-cookie" {
			for line in strings.split(x, "\n", context.temp_allocator) {
				for part, pi in strings.split(line, ";", context.temp_allocator) {
					// set-cookie: only the first pair is a cookie; the rest are attributes
					if lkey == "set-cookie" && pi > 0 do break
					eq := strings.index_byte(part, '=')
					if eq > 0 {
						val := strings.trim_space(part[eq + 1:])
						if len(val) >= 8 do out[strings.clone(val)] = "cookie"
					}
				}
			}
		}
		if strings.contains(x, "@") {
			for i in 0 ..< len(x) {
				if x[i] == '@' {
					if st, en, ok := email_span(x, i); ok && en - st >= 6 do out[strings.clone(x[st:en])] = "email"
				}
			}
		}
	case etf.List:
		for e in x do collect_secrets(e, key, out)
	case etf.Map:
		for p in x {
			k, _ := p.key.(string)
			collect_secrets(p.value, k, out)
		}
	}
}
