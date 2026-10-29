// verify collects every secret the raw capture contains (auth tokens, cookie
// values, identify token, emails, phones, fingerprints, installation ids,
// analytics/session tokens) and reports any that appear in the fixture text.
// Reports name the kind and location only, never the value.
verify :: (raw: string, fixture: string) -> []string {
    secrets: Table(string, string);  // value -> kind
    for l: lines_of(raw) {
        reset_temporary_storage();
        if !l continue;
        v, err := etf.from_json(l,, temp);
        if err != .None continue;
        collect_secrets(v, "", *secrets);
        b := gs(v, "m", "result", "body");
        if b.count > 0 && b.count < 8 << 20 {
            bv, berr := etf.from_json(b,, temp);
            if berr == .None collect_secrets(bv, "", *secrets);
        }
        // token-shaped strings anywhere in raw
        for i: 0..l.count-1 {
            n := token_at(l, i);
            if n > 0 table_set(*secrets, copy_string(slice(l, i, n)), "token-pattern");
        }
    }
    reset_temporary_storage();
    problems: [..]string;
    for kind, val: secrets {
        if val.count < 8 continue;
        at := find_index_from_left(fixture, val);
        if at < 0 continue;
        // context before the value, never the value itself
        before := slice(fixture, max(at - 60, 0), min(at, 60));
        escaped := replace(replace(replace(before, "\\", "\\\\"), "\"", "\\\""), "\n", "\\n");
        array_add(*problems, sprint("% value (len %) survives in fixture after \"%\"", kind, val.count, escaped));
    }
    for i: 0..fixture.count-1 if token_at(fixture, i) > 0 {
        array_add(*problems, sprint("token-shaped string at byte %", i));
        break;
    }
    return problems;
}

SECRET_KEYS :: string.[
    "token", "authorization", "email", "phone", "analytics_token", "fingerprint", "installation_id",
    "session_id", "auth_session_id_hash", "x-fingerprint", "x-installation-id", "password", "captcha_key", "ticket",
];

collect_secrets :: (v: etf.Value, key: string, out: *Table(string, string), depth := 0) {
    if depth > etf.MAX_DEPTH return;
    if v.kind == .List for v.list collect_secrets(it, key, out, depth + 1);
    if v.kind == .Map  for v.map collect_secrets(it.value, as_str(it.key), out, depth + 1);
    if v.kind != .String return;
    x := v.s;
    lkey := to_lower_copy(key,, temp);
    is_secret, k := array_find(SECRET_KEYS, lkey);
    if is_secret && x.count >= 8 table_set(out, copy_string(x), SECRET_KEYS[k]);
    if lkey == "cookie" || lkey == "set-cookie" {
        for line: split(x, "\n",, temp) for part, pi: split(line, ";",, temp) {
            // set-cookie: only the first pair is a cookie; the rest are attributes
            if lkey == "set-cookie" && pi > 0 break;
            eq := find_index_from_left(part, #char "=");
            if eq <= 0 continue;
            val := trim(slice(part, eq + 1, part.count - eq - 1));
            if val.count >= 8 table_set(out, copy_string(val), "cookie");
        }
    }
    for i: 0..x.count-1 if x[i] == #char "@" {
        st, en, ok := email_span(x, i);
        if ok && en - st >= 6 table_set(out, copy_string(slice(x, st, en - st)), "email");
    }
}
