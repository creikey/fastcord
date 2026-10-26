package voice

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Voice gateway protocol as spoken by the official desktop client
// (discord/0.0.419, RTCControlSocket in web.*.js):
//   wss://<endpoint>/?v=9   (v=10 only behind the 2026-04 sfu_update experiment)
//   JSON text frames {"op":N,"d":...}; server frames carry "seq" (v8+).
//   Binary frames: server [seq u16][op u8][payload], client [op u8][payload].

GATEWAY_VERSION :: 9

OP_IDENTIFY :: 0
OP_SELECT_PROTOCOL :: 1
OP_READY :: 2
OP_HEARTBEAT :: 3
OP_SESSION_DESCRIPTION :: 4
OP_SPEAKING :: 5
OP_HEARTBEAT_ACK :: 6
OP_RESUME :: 7
OP_HELLO :: 8
OP_RESUMED :: 9
OP_CLIENTS_CONNECT :: 11
OP_VIDEO :: 12
OP_CLIENT_DISCONNECT :: 13
OP_SESSION_UPDATE :: 14
OP_MEDIA_SINK_WANTS :: 15
OP_VOICE_BACKEND_VERSION :: 16
OP_FLAGS :: 18
OP_PLATFORM :: 20
OP_NO_ROUTE :: 32
OP_SFU_UPDATE :: 33

// close codes
CLOSE_FORCE :: 4000 // client close()
CLOSE_AUTHENTICATION_FAILED :: 4004
CLOSE_INVALID_SESSION :: 4006
CLOSE_SERVER_NOT_FOUND :: 4011
CLOSE_DISCONNECTED :: 4014
CLOSE_SERVER_CRASH :: 4015
CLOSE_CALL_TERMINATED :: 4022
CLOSE_HEARTBEAT_TIMEOUT :: 4800
CLOSE_UNRESUMABLE :: 4801
CLOSE_REPEATED_MLS_INVALID :: 4803
CLOSE_DAVE_DOWNGRADE_REFUSED :: 4804
CLOSE_DAVE_INVALID_MESSAGE :: 4805

SPEAKING_VOICE :: 1
SPEAKING_SOUNDSHARE :: 2
SPEAKING_PRIORITY :: 4

// Codec list exactly as the desktop client sends it in SELECT_PROTOCOL.
CODECS_JSON :: `[{"name":"opus","type":"audio","priority":1000,"payload_type":120},{"name":"AV1","type":"video","priority":1000,"payload_type":101,"rtx_payload_type":102,"encode":false,"decode":true},{"name":"H265","type":"video","priority":2000,"payload_type":103,"rtx_payload_type":104,"encode":true,"decode":true},{"name":"H264","type":"video","priority":3000,"payload_type":105,"rtx_payload_type":106,"encode":true,"decode":true},{"name":"VP8","type":"video","priority":4000,"payload_type":107,"rtx_payload_type":108,"encode":true,"decode":true}]`

// Experiments from READY the client opts into (RTCConnection._chooseExperiments).
SUPPORTED_EXPERIMENTS :: []string{"fixed_keyframe_interval"}

DEFAULT_USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36"

@(private)
json_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(b, `\u%04x`, c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

snowflake :: proc(v: u64, allocator := context.temp_allocator) -> string {
	buf: [24]byte
	return strings.clone(strconv.write_uint(buf[:], v, 10), allocator)
}

msg_identify :: proc(server_id, channel_id, user_id: u64, session_id, token: string, video: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":0,"d":{"server_id":`)
	json_str(&b, snowflake(server_id))
	strings.write_string(&b, `,"channel_id":`)
	json_str(&b, snowflake(channel_id))
	strings.write_string(&b, `,"user_id":`)
	json_str(&b, snowflake(user_id))
	strings.write_string(&b, `,"session_id":`)
	json_str(&b, session_id)
	strings.write_string(&b, `,"token":`)
	json_str(&b, token)
	strings.write_string(&b, `,"max_dave_protocol_version":1,"video":`)
	strings.write_string(&b, "true" if video else "false")
	strings.write_string(&b, `,"streams":[{"type":"video","rid":"100","quality":100}]}}`)
	return strings.to_string(b)
}

msg_resume :: proc(token, session_id: string, server_id, channel_id: u64, seq_ack: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":7,"d":{"token":`)
	json_str(&b, token)
	strings.write_string(&b, `,"session_id":`)
	json_str(&b, session_id)
	strings.write_string(&b, `,"server_id":`)
	json_str(&b, snowflake(server_id))
	strings.write_string(&b, `,"channel_id":`)
	json_str(&b, snowflake(channel_id))
	fmt.sbprintf(&b, `,"seq_ack":%d}}`, seq_ack)
	return strings.to_string(b)
}

msg_select_protocol :: proc(address: string, port: int, mode: Mode, rtc_connection_id: string, experiments: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"op":1,"d":{"protocol":"udp","data":{"address":`)
	json_str(&b, address)
	fmt.sbprintf(&b, `,"port":%d,"mode":`, port)
	json_str(&b, mode_name(mode))
	strings.write_string(&b, `},"address":`)
	json_str(&b, address)
	fmt.sbprintf(&b, `,"port":%d,"mode":`, port)
	json_str(&b, mode_name(mode))
	strings.write_string(&b, `,"codecs":`)
	strings.write_string(&b, CODECS_JSON)
	strings.write_string(&b, `,"rtc_connection_id":`)
	json_str(&b, rtc_connection_id)
	strings.write_string(&b, `,"experiments":[`)
	for e, i in experiments {
		if i > 0 do strings.write_byte(&b, ',')
		json_str(&b, e)
	}
	strings.write_string(&b, `]}}`)
	return strings.to_string(b)
}

msg_heartbeat :: proc(t_ms: i64, seq_ack: i64) -> string {
	return fmt.tprintf(`{{"op":3,"d":{{"t":%d,"seq_ack":%d}}}}`, t_ms, seq_ack)
}

msg_speaking :: proc(flags: int, ssrc: u32) -> string {
	return fmt.tprintf(`{{"op":5,"d":{{"speaking":%d,"delay":0,"ssrc":%d}}}}`, flags, ssrc)
}

msg_transition :: proc(op: int, transition_id: int) -> string {
	return fmt.tprintf(`{{"op":%d,"d":{{"transition_id":%d}}}}`, op, transition_id)
}

MSG_VOICE_BACKEND_VERSION :: `{"op":16,"d":{}}`

// uuid4 in the canonical lowercase form (rtc_connection_id).
uuid4 :: proc(allocator := context.allocator) -> string {
	r: [16]byte
	crypto.rand_bytes(r[:])
	r[6] = (r[6] & 0x0f) | 0x40
	r[8] = (r[8] & 0x3f) | 0x80
	return fmt.aprintf("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15], allocator = allocator)
}

// ---------------------------------------------------------------------------
// JSON access helpers (values from json.parse)

jget :: proc(v: json.Value, key: string) -> json.Value {
	o, ok := v.(json.Object)
	if !ok do return nil
	return o[key]
}

jint :: proc(v: json.Value, def: i64 = -1) -> i64 {
	#partial switch x in v {
	case json.Integer:
		return x
	case json.Float:
		return i64(x)
	case json.Boolean:
		return 1 if x else 0
	}
	return def
}

jstr :: proc(v: json.Value) -> string {
	s, ok := v.(json.String)
	return string(s) if ok else ""
}

jsnow :: proc(v: json.Value) -> u64 {
	#partial switch x in v {
	case json.String:
		n, ok := strconv.parse_u64(string(x))
		return n if ok else 0
	case json.Integer:
		return u64(x)
	}
	return 0
}

jarr :: proc(v: json.Value) -> json.Array {
	a, ok := v.(json.Array)
	return a if ok else nil
}
