package scrub

import "core:strings"
import "core:testing"

// A synthetic raw capture with fake secrets in every place real ones occur.
@(private = "file")
// Split so secret scanners do not flag this fake as a real token.
FAKE_TOKEN :: "MTU2NDIwMjkxODM2OTA0MjQ0Mg" + "." + "GaBcDe" + "." + "abcdefghijklmnopqrstuvwxyz0123456789AB"
@(private = "file")
RAW :: `{"rt":10.0,"acct":"a","m":{"method":"Network.requestWillBeSent","sessionId":"S","params":{"requestId":"1","wallTime":1793010000.0,"type":"XHR","request":{"method":"POST","url":"https://discord.com/api/v9/channels/1564227670806364343/messages?x=8a872f05-89b2-447c-a455-bbf5ed67b249","headers":{"Authorization":"` + FAKE_TOKEN + `","Cookie":"__dcfduid=0123456789abcdef; __sdcfduid=fedcba9876543210","X-Fingerprint":"1564202918369042442.fakefingerprintvalue","X-Super-Properties":"eyJjbGllbnRfbGF1bmNoX2lkIjoiOGE4NzJmMDUtODliMi00NDdjLWE0NTUtYmJmNWVkNjdiMjQ5In0="},"postData":"{\"content\":\"mail me at someone.private@example.org\",\"nonce\":\"1564240000000000000\"}"}}}}
{"rt":20.0,"acct":"a","mark":"send"}
{"rt":30.0,"acct":"a","m":{"method":"Network.responseReceived","sessionId":"S","params":{"requestId":"1","response":{"status":200,"protocol":"h3","connectionId":7,"connectionReused":true,"headers":{"set-cookie":"__cfruid=abcdefghijklmnop; path=/; Domain=discord.com","content-type":"application/json"}}}}}
{"rt":31.0,"acct":"a","body_for":"1","s":"S","m":{"id":9,"result":{"body":"{\"id\":\"1564240000000000001\",\"author\":{\"id\":\"181531813351522304\",\"username\":\"realperson\"},\"content\":\"private words\",\"email\":\"someone.private@example.org\",\"analytics_token\":\"QUFBQUFBQUFBQUFBQUFBQQ\"}","base64Encoded":false}}}
{"rt":40.0,"acct":"a","m":{"method":"Network.webSocketCreated","sessionId":"S","params":{"requestId":"W","url":"wss://gateway.discord.gg/?encoding=etf&v=9&compress=zstd-stream"}}}
{"rt":50.0,"acct":"a","gw":{"dir":"send","ws":"W","len":100},"etf":{"op":2,"d":{"token":"` + FAKE_TOKEN + `","properties":{"installation_id":"1564207173377069059.fakeinstallid"}}}}
{"rt":60.0,"acct":"a","gw":{"dir":"recv","ws":"W","len":100},"etf":{"op":0,"t":"READY","s":1,"d":{"session_id":"0123456789abcdef0123456789abcdef","user":{"id":"1546819257420087346","username":"dingusbattle","email":"someone.private@example.org","phone":"+15555550123"}}}}
`

@(private = "file")
ENV :: "A_ID=1546819257420087346\nTTEXT=1564227670806364343\n"

@(test)
test_scrub_removes_secrets :: proc(t: ^testing.T) {
	out := convert(RAW, ENV)
	problems := verify(RAW, out)
	testing.expectf(t, len(problems) == 0, "leaks: %v", problems)
	for bad in ([]string{FAKE_TOKEN, "someone.private", "0123456789abcdef", "fakefingerprint", "fakeinstallid", "+15555550123", "realperson", "private words", "181531813351522304", "QUFBQUFB"}) {
		testing.expectf(t, !strings.contains(out, bad), "%q survived", bad)
	}
	for want in ([]string{"<token>", "<cookie>", "<email>", "<nonce:1>", "<sid:1>", "<uuid:1>", "<user:1>", "<content>", "<new:1>", "1564227670806364343", "1546819257420087346", `"k":"mark"`, `"proto":"h3"`, `"k":"ws_send"`}) {
		testing.expectf(t, strings.contains(out, want), "%q missing from:\n%s", want, out)
	}
}

// verify must flag a fixture that still contains a secret.
@(test)
test_verify_catches_leak :: proc(t: ^testing.T) {
	leaky := strings.concatenate({`{"k":"req","headers":[["Authorization","`, FAKE_TOKEN, `"]]}`}, context.temp_allocator)
	testing.expect(t, len(verify(RAW, leaky)) > 0)
	testing.expect(t, len(verify(RAW, `{"x":"someone.private@example.org"}`)) > 0)
}
