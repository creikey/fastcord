// Voice gateway protocol as spoken by the official desktop client
// (discord/0.0.419, RTCControlSocket in web.*.js):
//   wss://<endpoint>/?v=9   (v=10 only behind the 2026-04 sfu_update experiment)
//   JSON text frames {"op":N,"d":...}; server frames carry "seq" (v8+).
//   Binary frames: server [seq u16][op u8][payload], client [op u8][payload].

GATEWAY_VERSION :: 9;

OP_IDENTIFY :: 0;
OP_SELECT_PROTOCOL :: 1;
OP_READY :: 2;
OP_HEARTBEAT :: 3;
OP_SESSION_DESCRIPTION :: 4;
OP_SPEAKING :: 5;
OP_HEARTBEAT_ACK :: 6;
OP_RESUME :: 7;
OP_HELLO :: 8;
OP_RESUMED :: 9;
OP_CLIENTS_CONNECT :: 11;
OP_VIDEO :: 12;
OP_CLIENT_DISCONNECT :: 13;
OP_SESSION_UPDATE :: 14;
OP_MEDIA_SINK_WANTS :: 15;
OP_VOICE_BACKEND_VERSION :: 16;
OP_FLAGS :: 18;
OP_PLATFORM :: 20;
OP_NO_ROUTE :: 32;
OP_SFU_UPDATE :: 33;

// close codes
CLOSE_FORCE :: 4000;  // client close()
CLOSE_AUTHENTICATION_FAILED :: 4004;
CLOSE_INVALID_SESSION :: 4006;
CLOSE_SERVER_NOT_FOUND :: 4011;
CLOSE_DISCONNECTED :: 4014;
CLOSE_SERVER_CRASH :: 4015;
CLOSE_CALL_TERMINATED :: 4022;
CLOSE_HEARTBEAT_TIMEOUT :: 4800;
CLOSE_UNRESUMABLE :: 4801;
CLOSE_REPEATED_MLS_INVALID :: 4803;
CLOSE_DAVE_DOWNGRADE_REFUSED :: 4804;
CLOSE_DAVE_INVALID_MESSAGE :: 4805;

SPEAKING_VOICE :: 1;
SPEAKING_SOUNDSHARE :: 2;
SPEAKING_PRIORITY :: 4;

// Codec list exactly as the desktop client sends it in SELECT_PROTOCOL.
CODECS_JSON :: "[{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120},{\"name\":\"AV1\",\"type\":\"video\",\"priority\":1000,\"payload_type\":101,\"rtx_payload_type\":102,\"encode\":false,\"decode\":true},{\"name\":\"H265\",\"type\":\"video\",\"priority\":2000,\"payload_type\":103,\"rtx_payload_type\":104,\"encode\":true,\"decode\":true},{\"name\":\"H264\",\"type\":\"video\",\"priority\":3000,\"payload_type\":105,\"rtx_payload_type\":106,\"encode\":true,\"decode\":true},{\"name\":\"VP8\",\"type\":\"video\",\"priority\":4000,\"payload_type\":107,\"rtx_payload_type\":108,\"encode\":true,\"decode\":true}]";

// Experiments from READY the client opts into (RTCConnection._chooseExperiments).
SUPPORTED_EXPERIMENTS :: string.["fixed_keyframe_interval"];

DEFAULT_USER_AGENT :: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) discord/0.0.419 Chrome/148.0.7778.280 Electron/42.11.15 Safari/537.36";

// json_str writes s as a JSON string; control bytes as \u00XX, everything else verbatim.
json_str :: (b: *String_Builder, s: string) {
    append(b, "\"");
    for cast([]u8) s {
        if it == {
          case #char "\""; append(b, "\\\"");
          case #char "\\"; append(b, "\\\\");
          case #char "\n"; append(b, "\\n");
          case #char "\r"; append(b, "\\r");
          case #char "\t"; append(b, "\\t");
          case;
            if it < 0x20 print_to_builder(b, "\\u%", formatInt(it, base = 16, minimum_digits = 4));
            else append(b, it);
        }
    }
    append(b, "\"");
}

// json_msg builds a message from parts: a string part is raw JSON, a Str part a JSON string (in temp).
Str :: struct { s: string; }
json_msg :: (parts: ..Any) -> string {
    b: String_Builder;
    b.allocator = temp;
    for parts {
        if it.type == type_info(Str) json_str(*b, (cast(*Str) it.value_pointer).s);
        else print_to_builder(*b, "%", it);
    }
    return builder_to_string(*b,, temp);
}

snowflake :: (v: u64) -> Str { return .{tprint("%", v)}; }

msg_identify :: (server_id: u64, channel_id: u64, user_id: u64, session_id: string, token: string, video: bool) -> string {
    return json_msg("{\"op\":0,\"d\":{\"server_id\":", snowflake(server_id), ",\"channel_id\":", snowflake(channel_id),
        ",\"user_id\":", snowflake(user_id), ",\"session_id\":", Str.{session_id}, ",\"token\":", Str.{token},
        ",\"max_dave_protocol_version\":1,\"video\":", ifx video then "true" else "false",
        ",\"streams\":[{\"type\":\"video\",\"rid\":\"100\",\"quality\":100}]}}");
}

msg_resume :: (token: string, session_id: string, server_id: u64, channel_id: u64, seq_ack: s64) -> string {
    return json_msg("{\"op\":7,\"d\":{\"token\":", Str.{token}, ",\"session_id\":", Str.{session_id},
        ",\"server_id\":", snowflake(server_id), ",\"channel_id\":", snowflake(channel_id), ",\"seq_ack\":", seq_ack, "}}");
}

msg_select_protocol :: (address: string, port: int, mode: Mode, rtc_connection_id: string, experiments: []string) -> string {
    b: String_Builder;
    b.allocator = temp;
    append(*b, json_msg("{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":", Str.{address}, ",\"port\":", port,
        ",\"mode\":", Str.{mode_name(mode)}, "},\"address\":", Str.{address}, ",\"port\":", port, ",\"mode\":", Str.{mode_name(mode)},
        ",\"codecs\":", CODECS_JSON, ",\"rtc_connection_id\":", Str.{rtc_connection_id}, ",\"experiments\":["));
    for experiments {
        if it_index append(*b, ",");
        json_str(*b, it);
    }
    append(*b, "]}}");
    return builder_to_string(*b,, temp);
}

msg_heartbeat :: (t_ms: s64, seq_ack: s64) -> string {
    return tprint("{\"op\":3,\"d\":{\"t\":%,\"seq_ack\":%}}", t_ms, seq_ack);
}

msg_speaking :: (flags: int, ssrc: u32) -> string {
    return tprint("{\"op\":5,\"d\":{\"speaking\":%,\"delay\":0,\"ssrc\":%}}", flags, ssrc);
}

msg_transition :: (op: int, transition_id: int) -> string {
    return tprint("{\"op\":%,\"d\":{\"transition_id\":%}}", op, transition_id);
}

MSG_VOICE_BACKEND_VERSION :: "{\"op\":16,\"d\":{}}";

// uuid4 in the canonical lowercase form (rtc_connection_id), in context.allocator.
uuid4 :: () -> string {
    r: [16]u8;
    crypto.random_bytes(r);
    r[6] = (r[6] & 0x0f) | 0x40;
    r[8] = (r[8] & 0x3f) | 0x80;
    b: String_Builder;
    for r {
        if it_index == 4 || it_index == 6 || it_index == 8 || it_index == 10 append(*b, "-");
        print_to_builder(*b, "%", formatInt(it, base = 16, minimum_digits = 2));
    }
    return builder_to_string(*b);
}

// ---------------------------------------------------------------------------
// JSON access helpers (values from etf.from_json)

jget :: (v: etf.Value, key: string) -> etf.Value {
    if v.kind != .Map return .{};
    x := etf.map_get(v.map, key);
    return x;
}

jint :: (v: etf.Value, def: s64 = -1) -> s64 {
    if v.kind == .Int   return v.i;
    if v.kind == .Float return cast(s64) v.f;
    if v.kind == .Bool  return ifx v.b then 1 else 0;
    return def;
}

jstr :: (v: etf.Value) -> string { return ifx v.kind == .String then v.s else ""; }

// jsnow reads a snowflake given as a decimal string or a number (0 if neither).
jsnow :: (v: etf.Value) -> u64 {
    if v.kind == .String {
        n: u64;
        if !v.s return 0;
        for cast([]u8) v.s {
            d := cast(u64) (it - #char "0");
            if it < #char "0" || it > #char "9" || n > (U64_MAX - d) / 10 return 0;
            n = n * 10 + d;
        }
        return n;
    }
    n, ok := etf.as_u64(v);
    if ok return n;
    return ifx v.kind == .Int then cast,no_check(u64) v.i else 0;
}

jarr :: (v: etf.Value) -> []etf.Value { return ifx v.kind == .List then v.list else .[]; }
