// Minimal Chrome DevTools Protocol client over a plaintext WebSocket.
// Used to observe (and drive) the official Discord desktop client.
package capture

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../src/wire"

Cdp :: struct {
	conn:    ^wire.Conn,
	ws:      ^wire.Ws,
	next_id: int,
}

// Finds the browser-level DevTools endpoint on a local debug port.
// Page-level connections die when the renderer reloads; the browser one doesn't.
cdp_find_browser :: proc(port: int) -> (ws_url: string, ok: bool) {
	c, err := wire.dial("127.0.0.1", port)
	if err != .None do return "", false
	defer wire.destroy(c)
	host := fmt.tprintf("127.0.0.1:%d", port)
	resp, rerr := wire.round_trip(c, "GET", "/json/version", {{"Host", host}, {"Connection", "close"}}, nil)
	defer wire.response_destroy(&resp)
	if rerr != .None || resp.status != 200 do return "", false
	v, jerr := json.parse(resp.body[:], allocator = context.temp_allocator)
	if jerr != nil do return "", false
	o := v.(json.Object) or_else nil
	url := o["webSocketDebuggerUrl"].(json.String) or_else ""
	if url == "" do return "", false
	return strings.clone(url), true
}

cdp_connect :: proc(ws_url: string) -> (cdp: Cdp, ok: bool) {
	// ws://127.0.0.1:9333/devtools/page/XYZ
	rest := strings.trim_prefix(ws_url, "ws://")
	slash := strings.index_byte(rest, '/')
	if slash < 0 do return {}, false
	hostport, path := rest[:slash], rest[slash:]
	colon := strings.last_index_byte(hostport, ':')
	port, _ := strconv.parse_int(hostport[colon + 1:])
	c, err := wire.dial(hostport[:colon], port)
	if err != .None do return {}, false
	ws, resp, herr := wire.ws_handshake(c, path, {{"Host", hostport}})
	wire.response_destroy(&resp)
	if herr != .None {
		wire.destroy(c)
		return {}, false
	}
	return Cdp{conn = c, ws = ws, next_id = 1}, true
}

// Sends a command; `params` is a JSON object literal (or "" for none).
cdp_send :: proc(cdp: ^Cdp, method: string, params := "", session := "") -> int {
	id := cdp.next_id
	cdp.next_id += 1
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":%d,"method":"%s"`, id, method)
	if params != "" do fmt.sbprintf(&b, `,"params":%s`, params)
	if session != "" do fmt.sbprintf(&b, `,"sessionId":"%s"`, session)
	strings.write_byte(&b, '}')
	wire.ws_send_text(cdp.ws, strings.to_string(b))
	return id
}

cdp_recv :: proc(cdp: ^Cdp, msg: ^wire.Ws_Message, timeout: time.Duration) -> wire.Error {
	if err := wire.poll(cdp.conn, timeout); err != .None do return err
	return wire.ws_recv(cdp.ws, msg)
}

cdp_close :: proc(cdp: ^Cdp) {
	wire.ws_destroy(cdp.ws)
	wire.destroy(cdp.conn)
}
