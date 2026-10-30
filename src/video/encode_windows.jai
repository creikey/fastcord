// Realtime H.264 encoding with the GPU's encoder MFT when there is one (asynchronous: it asks for input and
// announces output by events, polled at each frame), else Microsoft's synchronous software encoder. A
// hardware encoder that refuses a frame is swapped for the software one. H.265 only on the GPU (Windows has
// no software H.265 encoder). Output is delivered inside
// encoder_encode, on the caller's thread.

Encoder :: struct {
	mft: *void;
	hevc: bool;
	events: *void; // IMFMediaEventGenerator: the hardware encoder's (asynchronous)
	need_input: int; // METransformNeedInput not yet answered
	bitrate: int;
	api: *void; // ICodecAPI, if the MFT has one
	info: mf.MFT_OUTPUT_STREAM_INFO;
	width, height, fps: int;
	on_output: Encoded_Proc;
	user: *void;
	seq: [..]u8;  // the parameter sets (Annex B), for keyframes that come without them
	out: [..]u8;  // reused per output
	pts_hi: s64;  // pts_90k wraps every 13 h; the MFT needs increasing timestamps
	last_pts: u32;
}

encoder_supported :: (codec: Video_Codec) -> bool {
	if codec == .H265 {
		if hevc_ok == 0 {
			com := mf.com_enter();
			m := ifx mf.startup() then mf.transform_find(*mf.MFT_CATEGORY_VIDEO_ENCODER, *mf.MFVideoFormat_NV12, *mf.MFVideoFormat_HEVC, hardware = true) else null;
			hevc_ok = cast(s32) ifx m then 1 else 2;
			mf.release(m);
			mf.com_leave(com);
		}
		return hevc_ok == 1;
	}
	if h264_ok == 0 {
		com := mf.com_enter();
		m := ifx mf.startup() then mf.transform_find(*mf.MFT_CATEGORY_VIDEO_ENCODER, *mf.MFVideoFormat_NV12, *mf.MFVideoFormat_H264) else null;
		h264_ok = cast(s32) ifx m then 1 else 2;
		mf.release(m);
		mf.com_leave(com);
	}
	return h264_ok == 1;
}

encoder_create :: (codec: Video_Codec, width: int, height: int, fps: int, bitrate: int, on_output: Encoded_Proc, user: *void) -> *Encoder {
	if !encoder_supported(codec) return null;
	hevc := codec == .H265;
	e := ifx hevc || !software_only then encoder_open(true, hevc, width, height, fps, bitrate, on_output, user);
	if !e && !hevc e = encoder_open(false, false, width, height, fps, bitrate, on_output, user);
	if !e && hevc hevc_ok = 2;
	return e;
}

software_only := false; // a hardware encoder failed once: the next ones are software

encoder_open :: (hardware: bool, hevc: bool, width: int, height: int, fps: int, bitrate: int, on_output: Encoded_Proc, user: *void) -> *Encoder {
	com := mf.com_enter();
	defer mf.com_leave(com);
	format := ifx hevc then *mf.MFVideoFormat_HEVC else *mf.MFVideoFormat_H264;
	m := mf.transform_find(*mf.MFT_CATEGORY_VIDEO_ENCODER, *mf.MFVideoFormat_NV12, format, hardware = hardware);
	if !m return null;
	ok := false;
	api := mf.query(m, *mf.IID_ICodecAPI);
	events: *void;
	defer if !ok { mf.release(events); mf.release(api); mf.release(m); }
	// Before the media types, which fix the encoder's pipeline: set later, low latency still buffers 16 frames.
	attrs := mf.mft_attributes(m);
	if attrs {
		if hardware mf.set_u32(attrs, *mf.MF_TRANSFORM_ASYNC_UNLOCK, 1);
		mf.set_u32(attrs, *mf.MF_LOW_LATENCY, 1);
		mf.release(attrs);
	}
	if hardware {
		events = mf.query(m, *mf.IID_IMFMediaEventGenerator);
		if !events return null;
	}
	if api {
		mf.codec_set_bool(api, *mf.MF_LOW_LATENCY, true);
		mf.codec_set_u32(api, *mf.CODECAPI_AVEncCommonRateControlMode, 0); // CBR
		mf.codec_set_u32(api, *mf.CODECAPI_AVEncCommonMeanBitRate, xx bitrate);
		mf.codec_set_u32(api, *mf.CODECAPI_AVEncMPVGOPSize, xx (fps * 2));
		mf.codec_set_u32(api, *mf.CODECAPI_AVEncMPVDefaultBPictureCount, 0);
	}

	// Output before input: the encoder only offers input types once it has an output type.
	set_output :: (m: *void, format: *GUID, w: int, h: int, fps: int, bitrate: int, profile: u32) -> bool {
		t := mf.video_type(format, w, h, fps);
		if !t return false;
		defer mf.release(t);
		mf.set_u32(t, *mf.MF_MT_AVG_BITRATE, xx bitrate);
		mf.set_u32(t, *mf.MF_MT_MPEG2_PROFILE, profile);
		return mf.mft_set_output_type(m, t) >= 0;
	}
	// H.264: eAVEncH264VProfile_ConstrainedBase (Windows 8+), else _Base; H.265: Main.
	if hevc { if !set_output(m, format, width, height, fps, bitrate, 1) return null; }
	else if !set_output(m, format, width, height, fps, bitrate, 256) && !set_output(m, format, width, height, fps, bitrate, 66) return null;
	t := mf.video_type(*mf.MFVideoFormat_NV12, width, height, fps);
	if !t return null;
	in_ok := mf.mft_set_input_type(m, t) >= 0;
	mf.release(t);
	if !in_ok return null;

	e := New(Encoder);
	e.* = .{mft = m, hevc = hevc, api = api, events = events, bitrate = bitrate, width = width, height = height, fps = max(fps, 1), on_output = on_output, user = user};
	cur := mf.mft_output_current_type(m);
	if cur {
		hdr: [1024]u8;
		n := mf.get_blob(cur, *mf.MF_MT_MPEG_SEQUENCE_HEADER, hdr);
		mf.annexb_append(*e.seq, array_view(hdr, 0, n));
		mf.release(cur);
	}
	e.info = mf.mft_output_info(m);
	mf.mft_message(m, mf.MFT_MESSAGE_NOTIFY_BEGIN_STREAMING);
	mf.mft_message(m, mf.MFT_MESSAGE_NOTIFY_START_OF_STREAM);
	ok = true;
	return e;
}

// encoder_set_bitrate changes the mean bitrate between frames (the bandwidth estimate moved): CBR's
// CODECAPI_AVEncCommonMeanBitRate, which encoders take while streaming.
encoder_set_bitrate :: (e: *Encoder, bitrate: int) {
	e.bitrate = bitrate;
	if !e.api return;
	com := mf.com_enter();
	defer mf.com_leave(com);
	mf.codec_set_u32(e.api, *mf.CODECAPI_AVEncCommonMeanBitRate, xx bitrate);
}

// pixbuf: an yuv.Nv12, scaled to the encoder's size.
encoder_encode :: (e: *Encoder, pixbuf: *void, pts_90k: u32, force_keyframe := false) {
	f := yuv.nv12_scaled(cast(*yuv.Nv12) pixbuf, e.width, e.height);
	defer yuv.nv12_release(f);
	if f.width != e.width || f.height != e.height return;
	com := mf.com_enter();
	defer mf.com_leave(com);
	if pts_90k < e.last_pts && e.last_pts - pts_90k > 0x8000_0000 e.pts_hi += 0x1_0000_0000;
	e.last_pts = pts_90k;
	if force_keyframe && e.api mf.codec_set_u32(e.api, *mf.CODECAPI_AVEncVideoForceKeyFrame, 1);
	s := mf.sample_from_bytes(f.data, ((e.pts_hi + pts_90k) * 1000 + 4) / 9, 10_000_000 / e.fps);
	if !s return;
	defer mf.release(s);
	if e.events {
		// hardware: answer what it asked for since the last frame; a frame it hasn't asked for is dropped
		pump(e);
		if e.need_input > 0 {
			if mf.mft_input(e.mft, s) < 0 { to_software(e); return; }
			e.need_input -= 1;
		}
		pump(e);
		return;
	}
	hr := mf.mft_input(e.mft, s);
	if hr == mf.MF_E_NOTACCEPTING {
		drain(e);
		hr = mf.mft_input(e.mft, s);
	}
	drain(e);
}

encoder_destroy :: (e: *Encoder) {
	if !e return;
	com := mf.com_enter();
	defer mf.com_leave(com);
	mf.mft_message(e.mft, mf.MFT_MESSAGE_NOTIFY_END_OF_STREAM);
	if e.events mf.mft_message(e.mft, mf.MFT_MESSAGE_NOTIFY_END_STREAMING);
	mf.release(e.events);
	mf.release(e.api);
	mf.release(e.mft);
	array_free(e.seq);
	array_free(e.out);
	free(e);
}

#scope_file

h264_ok: s32; // 0 unknown, 1 yes, 2 no
hevc_ok: s32; // likewise, on the GPU

// pump handles the hardware encoder's waiting events: input it asks for is counted, output delivered.
pump :: (e: *Encoder) {
	for 0..63 {
		t := mf.mft_event(e.events);
		if t == mf.METransformNeedInput e.need_input += 1;
		else if t == mf.METransformHaveOutput drain(e, 1);
		else if !t return;
	}
}

// to_software: the hardware encoder failed a frame; the rest goes through the software one (and the next
// encoders start there), at the same size and rate.
to_software :: (e: *Encoder) {
	if e.hevc { hevc_ok = 2; return; } // no software H.265: the app goes back to H.264 at the next frame
	software_only = true;
	sw := encoder_open(false, false, e.width, e.height, e.fps, e.bitrate, e.on_output, e.user);
	if !sw return;
	mf.release(e.events);
	mf.release(e.api);
	mf.release(e.mft);
	array_free(e.seq);
	array_free(e.out);
	e.* = sw.*;
	free(sw);
}

drain :: (e: *Encoder, at_most := 16) {
	for 1..at_most {
		s, hr := mf.mft_output(e.mft, e.info);
		if hr == mf.MF_E_TRANSFORM_STREAM_CHANGE {
			t := mf.mft_output_available_type(e.mft, 0);
			if !t return;
			mf.mft_set_output_type(e.mft, t);
			mf.release(t);
			e.info = mf.mft_output_info(e.mft);
			continue;
		}
		if hr < 0 return;
		defer mf.release(s);
		clean := mf.get_u32(s, *mf.MFSampleExtension_CleanPoint);
		buf, bytes := mf.sample_lock(s);
		if !buf continue;
		keyframe := clean != 0;
		e.out.count = 0;
		if keyframe && !has_params(bytes, e.hevc) array_add(*e.out, ..e.seq);
		mf.annexb_append(*e.out, bytes);
		mf.sample_unlock(buf);
		pts := cast,trunc(u32) ((mf.sample_time(s) * 9 + 500) / 1000);
		e.on_output(e.user, e.out, keyframe, pts);
	}
}

// has_params: the access unit carries its SPS (H.265: VPS).
has_params :: (annexb: []u8, hevc: bool) -> bool {
	for i: 0..annexb.count - 4 if annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1 {
		b := annexb[i + 3];
		if (hevc && ((b >> 1) & 0x3f) == 32) || (!hevc && (b & 0x1f) == 7) return true;
	}
	return false;
}
