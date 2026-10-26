// gwdump: decodes the gateway WebSocket frames in a raw capture
// (zstd-stream + ETF) and prints one JSON line per payload.
//   gwdump <raw.jsonl>
package gwdump

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "../../src/etf"
import "../../src/zstd"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: gwdump <raw.jsonl>")
		os.exit(2)
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("read failed")
		os.exit(1)
	}
	gateway_ids := make(map[string]bool)
	decoders := make(map[string]^zstd.Decoder)
	ok_count, bad := 0, 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.contains(line, "webSocket") do continue
		v, jerr := json.parse_string(line, allocator = context.temp_allocator)
		if jerr != nil do continue
		r := v.(json.Object)
		m := r["m"].(json.Object)
		method := m["method"].(json.String) or_else ""
		params := m["params"].(json.Object) or_else nil
		rid := params["requestId"].(json.String) or_else ""
		rt := r["rt"].(json.Float) or_else 0
		switch method {
		case "Network.webSocketCreated":
			url := params["url"].(json.String) or_else ""
			if strings.contains(url, "zstd-stream") {
				gateway_ids[strings.clone(rid)] = true
				d := new(zstd.Decoder)
				decoders[strings.clone(rid)] = d
			}
			fmt.printfln(`{{"rt":%.1f,"ws":"%s","url":"%s"}}`, rt, rid, url)
		case "Network.webSocketFrameSent", "Network.webSocketFrameReceived":
			resp := params["response"].(json.Object)
			op := int(resp["opcode"].(json.Float) or_else 0)
			payload := resp["payloadData"].(json.String) or_else ""
			dir := method == "Network.webSocketFrameSent" ? "send" : "recv"
			if op == 1 {
				fmt.printfln(`{{"rt":%.1f,"ws":"%s","dir":"%s","text":%s}}`, rt, rid, dir, payload)
				continue
			}
			raw, berr := base64.decode(payload, allocator = context.temp_allocator)
			if berr != nil do continue
			bytes := raw
			if dir == "recv" && gateway_ids[rid] {
				out := make([dynamic]byte, context.temp_allocator)
				zerr := zstd.feed(decoders[rid], raw, &out)
				if zerr != .None {
					fmt.eprintfln("zstd error %v at rt=%.1f (len %d)", zerr, rt, len(raw))
					bad += 1
					continue
				}
				bytes = out[:]
			}
			t, eerr := etf.decode(bytes, context.temp_allocator)
			if eerr != .None {
				fmt.eprintfln("etf error %v at rt=%.1f dir=%s", eerr, rt, dir)
				bad += 1
				continue
			}
			ok_count += 1
			fmt.printfln(`{{"rt":%.1f,"ws":"%s","dir":"%s","etf":%s}}`, rt, rid, dir, etf.to_json(t, context.temp_allocator))
		}
		free_all(context.temp_allocator)
	}
	fmt.eprintfln("decoded %d frames, %d errors", ok_count, bad)
}
