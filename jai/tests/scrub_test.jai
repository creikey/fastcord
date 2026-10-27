// tools/scrub/scrub_test.odin for the Jai scrub: jai build.jai - run jai/tests/scrub_test.jai && build/scrub_test
#import "Basic";
#import "String";
scrub :: #import "tool_scrub";

// A synthetic raw capture with fake secrets in every place real ones occur.
// Split so secret scanners do not flag this fake as a real token.
FAKE_TOKEN :: #run join("MTU2NDIwMjkxODM2OTA0MjQ0Mg", ".", "GaBcDe", ".", "abcdefghijklmnopqrstuvwxyz0123456789AB");
RAW_TEMPLATE :: #string END
{"rt":10.0,"acct":"a","m":{"method":"Network.requestWillBeSent","sessionId":"S","params":{"requestId":"1","wallTime":1793010000.0,"type":"XHR","request":{"method":"POST","url":"https://discord.com/api/v9/channels/1564227670806364343/messages?x=8a872f05-89b2-447c-a455-bbf5ed67b249","headers":{"Authorization":"@TOKEN@","Cookie":"__dcfduid=0123456789abcdef; __sdcfduid=fedcba9876543210","X-Fingerprint":"1564202918369042442.fakefingerprintvalue","X-Super-Properties":"eyJjbGllbnRfbGF1bmNoX2lkIjoiOGE4NzJmMDUtODliMi00NDdjLWE0NTUtYmJmNWVkNjdiMjQ5In0="},"postData":"{\"content\":\"mail me at someone.private@example.org\",\"nonce\":\"1564240000000000000\"}"}}}}
{"rt":20.0,"acct":"a","mark":"send"}
{"rt":30.0,"acct":"a","m":{"method":"Network.responseReceived","sessionId":"S","params":{"requestId":"1","response":{"status":200,"protocol":"h3","connectionId":7,"connectionReused":true,"headers":{"set-cookie":"__cfruid=abcdefghijklmnop; path=/; Domain=discord.com","content-type":"application/json"}}}}}
{"rt":31.0,"acct":"a","body_for":"1","s":"S","m":{"id":9,"result":{"body":"{\"id\":\"1564240000000000001\",\"author\":{\"id\":\"181531813351522304\",\"username\":\"realperson\"},\"content\":\"private words\",\"email\":\"someone.private@example.org\",\"analytics_token\":\"QUFBQUFBQUFBQUFBQUFBQQ\"}","base64Encoded":false}}}
{"rt":40.0,"acct":"a","m":{"method":"Network.webSocketCreated","sessionId":"S","params":{"requestId":"W","url":"wss://gateway.discord.gg/?encoding=etf&v=9&compress=zstd-stream"}}}
{"rt":50.0,"acct":"a","gw":{"dir":"send","ws":"W","len":100},"etf":{"op":2,"d":{"token":"@TOKEN@","properties":{"installation_id":"1564207173377069059.fakeinstallid"}}}}
{"rt":60.0,"acct":"a","gw":{"dir":"recv","ws":"W","len":100},"etf":{"op":0,"t":"READY","s":1,"d":{"session_id":"0123456789abcdef0123456789abcdef","user":{"id":"1546819257420087346","username":"dingusbattle","email":"someone.private@example.org","phone":"+15555550123"}}}}
END

ENV :: "A_ID=1546819257420087346\nTTEXT=1564227670806364343\n";

// Telemetry batches keep their structure (event types, property keys, value
// types, constant values) so the parity tests can compare them; only secrets
// and session ids become placeholders.
RAW_SCIENCE_TEMPLATE :: #string END
{"rt":10.0,"acct":"a","m":{"method":"Network.requestWillBeSent","sessionId":"S","params":{"requestId":"5","wallTime":1793010000.0,"type":"XHR","request":{"method":"POST","url":"https://discord.com/api/v9/science","headers":{"Authorization":"@TOKEN@","Content-Type":"application/json"},"postData":"{\"token\":\"QUFBQUFBQUFBQUFBQUFBQQ\",\"events\":[{\"type\":\"search_opened\",\"properties\":{\"client_track_timestamp\":1793018881613,\"client_heartbeat_session_id\":\"8a872f05-89b2-447c-a455-bbf5ed67b249\",\"event_sequence_number\":27,\"search_type\":\"EMOJI_REACTION\",\"load_id\":\"0ae6e1db9cea47448f6dd018605f46e5\",\"guild_id\":\"1564227669971832975\",\"guild_is_vip\":false,\"guild_member_perms\":\"17873661021126655\",\"location\":\"Guild Channel\",\"location_stack\":[\"username\",\"user profile popout\"],\"client_performance_cpu\":0.08049154022486228,\"client_send_timestamp\":1793018881619}}]}"}}}}
END

failures := 0;
expect :: (ok: bool, what: string, arg: string) {
    if ok return;
    print("FAIL: % %\n", what, arg);
    failures += 1;
}

main :: () {
    // the scrub removes every secret
    RAW := replace(RAW_TEMPLATE, "@TOKEN@", FAKE_TOKEN);
    RAW_SCIENCE := replace(RAW_SCIENCE_TEMPLATE, "@TOKEN@", FAKE_TOKEN);
    out := scrub.convert(RAW, ENV);
    expect(scrub.verify(RAW, out).count == 0, "leaks in", "convert(RAW)");
    for string.[FAKE_TOKEN, "someone.private", "0123456789abcdef", "fakefingerprint", "fakeinstallid", "+15555550123", "realperson", "private words", "181531813351522304", "QUFBQUFB"]
        expect(!contains(out, it), "survived:", it);
    for string.["<token>", "<cookie>", "<email>", "<nonce:1>", "<sid:1>", "<uuid:1>", "<user:1>", "<content>", "<new:1>", "1564227670806364343", "1546819257420087346", "\"k\":\"mark\"", "\"proto\":\"h3\"", "\"k\":\"ws_send\""]
        expect(contains(out, it), "missing:", it);

    // verify must flag a fixture that still contains a secret
    expect(scrub.verify(RAW, join("{\"k\":\"req\",\"headers\":[[\"Authorization\",\"", FAKE_TOKEN, "\"]]}")).count > 0, "verify missed", "a token");
    expect(scrub.verify(RAW, "{\"x\":\"someone.private@example.org\"}").count > 0, "verify missed", "an email");

    // telemetry keeps its structure
    out = scrub.convert(RAW_SCIENCE, ENV);
    expect(scrub.verify(RAW_SCIENCE, out).count == 0, "leaks in", "convert(RAW_SCIENCE)");
    for string.[FAKE_TOKEN, "QUFBQUFB", "8a872f05-89b2"] expect(!contains(out, it), "survived:", it);
    for string.["\"events\":[{\"type\":\"search_opened\",\"properties\":{\"client_track_timestamp\":1793018881613,\"client_heartbeat_session_id\":", "\"search_type\":\"EMOJI_REACTION\"",
        "\"guild_is_vip\":false", "\"guild_member_perms\":\"17873661021126655\"", "\"location\":\"Guild Channel\"", "\"location_stack\":[\"username\",\"user profile popout\"]",
        "\"client_performance_cpu\":0.08049154022486228", "\"client_send_timestamp\":1793018881619"]
        expect(contains(out, it), "missing:", it);

    if failures exit(1);
    print("scrub tests ok\n");
}
