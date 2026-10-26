// capture: records every HTTP request/response and WebSocket frame the
// official Discord desktop client makes, via the DevTools protocol.
//
//   capture -port:9333 -out:.secrets/raw/x.jsonl [-seconds:60] [-reload]
//
// Output is raw (unscrubbed) JSONL, one CDP event per line, wrapped as
//   {"rt":<ms since start>,"s":"<cdp session>","m":<cdp message>}
// It contains the account token, so it must stay under .secrets/.
// `scrub` turns it into a committable capture.
package capture

import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../src/wire"

Options :: struct {
	port:    int `usage:"DevTools port of the Discord instance"`,
	out:     string `usage:"output JSONL path"`,
	seconds: int `usage:"stop after this many seconds (0 = until stop file)"`,
	reload:  bool `usage:"reload the client after attaching (records a cold start)"`,
	stop:    string `usage:"stop when this file exists"`,
}

main :: proc() {
	opt := Options{port = 9333, seconds = 0, stop = ".secrets/capture.stop"}
	flags.parse_or_exit(&opt, os.args, .Odin)
	if opt.out == "" {
		fmt.eprintln("missing -out")
		os.exit(2)
	}
	os.remove(opt.stop)

	page, ok := cdp_find_browser(opt.port)
	if !ok {
		fmt.eprintfln("no discord page on port %d", opt.port)
		os.exit(1)
	}
	cdp, cok := cdp_connect(page)
	if !cok {
		fmt.eprintln("cdp connect failed")
		os.exit(1)
	}
	defer cdp_close(&cdp)

	f, ferr := os.open(opt.out, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if ferr != nil {
		fmt.eprintln("cannot open", opt.out)
		os.exit(1)
	}
	defer os.close(f)

	NET_PARAMS :: `{"maxTotalBufferSize":200000000,"maxResourceBufferSize":100000000,"maxPostDataSize":100000000}`
	cdp_send(&cdp, "Target.setAutoAttach", `{"autoAttach":true,"waitForDebuggerOnStart":true,"flatten":true}`)
	reloaded := !opt.reload

	// command id -> (session, requestId) for pending getResponseBody calls
	Pending :: struct {
		session:    string,
		request_id: string,
	}
	pending := make(map[int]Pending)

	start := time.tick_now()
	msg: wire.Ws_Message
	defer delete(msg.data)
	events := 0
	for {
		if opt.seconds > 0 && time.tick_since(start) > time.Duration(opt.seconds) * time.Second do break
		if os.exists(opt.stop) do break

		err := cdp_recv(&cdp, &msg, 250 * time.Millisecond)
		if err == .Timeout do continue
		if err != .None {
			fmt.eprintln("cdp recv error:", err)
			break
		}
		if msg.opcode == .Close do break
		rt := f64(time.tick_since(start)) / f64(time.Millisecond)

		v, jerr := json.parse(msg.data[:], allocator = context.temp_allocator)
		if jerr != nil do continue
		o := v.(json.Object) or_else nil
		session := o["sessionId"].(json.String) or_else ""
		method := o["method"].(json.String) or_else ""
		params := o["params"].(json.Object) or_else nil

		// Responses to our own commands: only bodies are interesting.
		if id_v, has_id := o["id"]; has_id {
			id := int(id_v.(json.Float) or_else 0)
			if p, is_body := pending[id]; is_body {
				delete_key(&pending, id)
				fmt.fprintf(f, `{{"rt":%.3f,"s":"%s","body_for":"%s","m":%s}}`+"\n", rt, p.session, p.request_id, string(msg.data[:]))
				delete(p.session)
				delete(p.request_id)
				events += 1
			}
			free_all(context.temp_allocator)
			continue
		}

		switch method {
		case "Target.attachedToTarget":
			// Watch workers and iframes too, then let them run.
			child := params["sessionId"].(json.String) or_else ""
			cdp_send(&cdp, "Network.enable", NET_PARAMS, child)
			cdp_send(&cdp, "Target.setAutoAttach", `{"autoAttach":true,"waitForDebuggerOnStart":true,"flatten":true}`, child)
			cdp_send(&cdp, "Runtime.runIfWaitingForDebugger", "", child)
			info := params["targetInfo"].(json.Object) or_else nil
			url := info["url"].(json.String) or_else ""
			if !reloaded && (info["type"].(json.String) or_else "") == "page" && strings.contains(url, "discord.com") {
				cdp_send(&cdp, "Page.reload", `{"ignoreCache":false}`, child)
				reloaded = true
			}
		case "Network.loadingFinished":
			rid := params["requestId"].(json.String) or_else ""
			id := cdp_send(&cdp, "Network.getResponseBody", fmt.tprintf(`{{"requestId":"%s"}}`, rid), session)
			pending[id] = {strings.clone(session), strings.clone(rid)}
		}

		if strings.has_prefix(method, "Network.") || strings.has_prefix(method, "Target.") || method == "Page.frameNavigated" {
			fmt.fprintf(f, `{{"rt":%.3f,"s":"%s","m":%s}}`+"\n", rt, session, string(msg.data[:]))
			events += 1
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("captured %d events -> %s", events, opt.out)
}
