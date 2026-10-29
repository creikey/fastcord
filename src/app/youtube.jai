// YouTube cards played in fastcord's own player through the user's own yt-dlp (fastcord never ships or
// downloads it, and never a webview). Opt-in: the first play asks; Settings > Chat can change it. yt-dlp
// runs on a thread with -g, which prints the address of one progressive H.264 MP4 format (video and audio
// together, at most 1080p), and the player streams that from YouTube directly. Without yt-dlp, or on any
// failure (a bot check included), the link opens in the browser as before.

YT_ASK :: 0;
YT_ON :: 1;
YT_OFF :: 2;
youtube_ytdlp := YT_ASK; // settings.json youtube_ytdlp

Yt_State :: enum u8 { Resolving; Ready; Failed; }

Yt_Video :: struct {
	state: Yt_State; // atomic once the thread runs
	failed_seen: bool; // the browser opened for the failure (UI thread)
	page: string; // heap
	stream: string; // heap: the format's address, set by the thread before Ready
	thread: Thread;
}

yt_videos: [..]*Yt_Video;
yt_ask: dc.Snowflake; // the embed whose first play is asking (embed_player_key)

// youtube_play: the poster was clicked. The stream's address once yt-dlp found it ("" while it looks, or
// after it failed and the browser opened).
youtube_play :: (page: string) -> *Yt_Video {
	for yt_videos if it.page == page return it;
	v := New(Yt_Video);
	v.page = copy_string(page);
	array_add(*yt_videos, v);
	thread_init(*v.thread, (t: *Thread) -> s64 {
		v := cast(*Yt_Video) t.data;
		v.stream = ytdlp_resolve(v.page);
		atomic_store(*v.state, ifx v.stream then Yt_State.Ready else .Failed);
		platform.request_frame();
		return 0;
	});
	v.thread.data = v;
	thread_start(*v.thread);
	return v;
}

youtube_find :: (page: string) -> *Yt_Video {
	for yt_videos if it.page == page return it;
	return null;
}

yt_ready :: (page: string) -> bool {
	v := youtube_find(page);
	return v && atomic_load(*v.state) == .Ready;
}

is_youtube :: (u: string) -> bool {
	h := url_host(u);
	return h == "www.youtube.com" || h == "youtube.com" || h == "m.youtube.com" || h == "youtu.be" || h == "music.youtube.com";
}

#scope_file

// Progressive H.264 + AAC in MP4 (what the player decodes everywhere), the best up to 1080p.
YT_FORMAT :: "best[ext=mp4][vcodec^=avc1][acodec!=none][height<=1080]/best[ext=mp4][acodec!=none][vcodec!=none]";

ytdlp_resolve :: (page: string) -> string {
	#if OS == .WINDOWS candidates := string.["yt-dlp.exe"];
	else candidates := string.["yt-dlp", "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", tprint("%/.local/bin/yt-dlp", home_dir())];
	for exe: candidates {
		if contains(exe, "/") && !file_exists(exe) continue;
		r, out := run_command(exe, "-g", "-f", YT_FORMAT, "--no-playlist", "--no-warnings", "--", page, capture_and_return_output = true);
		if r.type != .EXITED || r.exit_code == 127 continue; // not there
		if r.exit_code != 0 return "";
		line := trim(out);
		nl := find_index_from_left(line, #char "\n");
		if nl >= 0 line.count = nl;
		line = trim(line);
		if !begins_with(line, "https://") || line.count > 8192 return "";
		for cast([]u8) line if it <= #char " " || it >= 0x7f return "";
		return copy_string(line);
	}
	return "";
}

home_dir :: () -> string { return env_var("HOME"); }
