// Camera capture through V4L2: the first /dev/video* that captures, in NV12, YUYV or MJPEG (decoded by Wuffs),
// converted to NV12 on the capture's thread. Screens are in screen_linux.jai.

// Opening devices can take a while, so this only knows what the last camera_start found: until then,
// assume there is one.
camera_supported :: () -> bool { return atomic_load(*camera_count) != 0; }

camera_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30, device_id := "") -> *Capture {
	c := New(Capture);
	c.* = .{on_frame = on_frame, user = user, width = width, height = height, fps = fps, camera = true, device = copy_string(device_id)};
	start(c, camera_thread);
	return c;
}

#scope_file

camera_count: s32 = -1; // unknown

#scope_module

// The capture devices, by their V4L2 card names.
list_cameras :: () -> [..]Camera_Device {
	out: [..]Camera_Device;
	for i: 0..63 {
		path := tprint("/dev/video%", i);
		fd := open(temp_c_string(path), O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if fd < 0 continue;
		defer close(fd);
		cap: v4l2_capability;
		if xioctl(fd, VIDIOC_QUERYCAP, *cap) < 0 continue;
		caps := ifx cap.capabilities & CAP_DEVICE_CAPS then cap.device_caps else cap.capabilities;
		if !(caps & CAP_VIDEO_CAPTURE) || !(caps & CAP_STREAMING) continue;
		name := to_string(cap.card.data, c_style_strlen(cap.card.data));
		array_add(*out, .{copy_string(path), copy_string(ifx name then name else path)});
	}
	return out;
}

#scope_file

Mode :: struct { fourcc: u32; w, h, fps: int; }

FOURCC_NV12 :: #run fourcc("NV12");
FOURCC_YUYV :: #run fourcc("YUYV");
FOURCC_MJPG :: #run fourcc("MJPG");
fourcc :: (s: string) -> u32 { return (cast(u32) s[0]) | ((cast(u32) s[1]) << 8) | ((cast(u32) s[2]) << 16) | ((cast(u32) s[3]) << 24); }

camera_thread :: (t: *Thread) -> s64 {
	c := cast(*Capture) t.data;
	// A camera stopped a moment ago (turned off and on, switched, or the settings' test handing it to the
	// call) is still held by its old thread, and V4L2 refuses a second stream with EBUSY: retry a while.
	until := current_time_monotonic() + seconds_to_apollo(3);
	while capture_camera(c) && !atomic_load(*c.quit) {
		if current_time_monotonic() > until { log_error("camera: still busy after 3 s"); break; }
		sleep_milliseconds(100);
	}
	return 0;
}

// Streams one camera until quit or a failure, which sets c.error. Returns whether the device was busy
// before it streamed (worth retrying).
capture_camera :: (c: *Capture) -> busy: bool {
	fd, mode := open_camera(c);
	if fd < 0 return false;
	defer close(fd);

	f: v4l2_format;
	f.type = BUF_TYPE_VIDEO_CAPTURE;
	f.pix = .{width = xx mode.w, height = xx mode.h, pixelformat = mode.fourcc, field = 1}; // V4L2_FIELD_NONE
	if xioctl(fd, VIDIOC_S_FMT, *f) < 0 return v4l2_fail(c, "VIDIOC_S_FMT");
	w, h, bpl, fmt := cast(int) f.pix.width, cast(int) f.pix.height, cast(int) f.pix.bytesperline, f.pix.pixelformat;
	if fmt != FOURCC_NV12 && fmt != FOURCC_YUYV && fmt != FOURCC_MJPG { c.error = "The camera's video format isn't supported."; return false; }
	parm: v4l2_streamparm;
	parm.type = BUF_TYPE_VIDEO_CAPTURE;
	parm.timeperframe = .{1, xx max(mode.fps, 1)};
	xioctl(fd, VIDIOC_S_PARM, *parm); // a camera without frame rate control keeps its own

	req := v4l2_requestbuffers.{count = 4, type = BUF_TYPE_VIDEO_CAPTURE, memory = MEMORY_MMAP};
	if xioctl(fd, VIDIOC_REQBUFS, *req) < 0 return v4l2_fail(c, "VIDIOC_REQBUFS");
	if req.count < 2 { c.error = "Couldn't start the camera."; return false; }
	maps: [8][]u8;
	n := min(cast(int) req.count, maps.count);
	defer for maps if it.data munmap(it.data, xx it.count);
	for i: 0..n - 1 {
		b := v4l2_buffer.{index = xx i, type = BUF_TYPE_VIDEO_CAPTURE, memory = MEMORY_MMAP};
		if xioctl(fd, VIDIOC_QUERYBUF, *b) < 0 return v4l2_fail(c, "VIDIOC_QUERYBUF");
		p := mmap(null, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.offset);
		if p == MAP_FAILED return v4l2_fail(c, "mmap");
		maps[i] = .{b.length, p};
		if xioctl(fd, VIDIOC_QBUF, *b) < 0 return v4l2_fail(c, "VIDIOC_QBUF");
	}
	type: s32 = BUF_TYPE_VIDEO_CAPTURE;
	if xioctl(fd, VIDIOC_STREAMON, *type) < 0 return v4l2_fail(c, "VIDIOC_STREAMON");
	defer xioctl(fd, VIDIOC_STREAMOFF, *type);
	c.error = "";

	jpeg: Jpeg;
	defer { free(jpeg.state.data); free(jpeg.work.data); free(jpeg.rgba.data); array_free(jpeg.fixed); }
	io_errors := 0; // EIO is a lost buffer (a USB hiccup), not the end; many in a row are
	while !atomic_load(*c.quit) {
		pfd := pollfd.{fd = fd, events = POLLIN};
		r := poll(*pfd, 1, 100);
		if r < 0 && errno() != EINTR { v4l2_fail(c, "poll"); break; }
		if r <= 0 continue;
		b := v4l2_buffer.{type = BUF_TYPE_VIDEO_CAPTURE, memory = MEMORY_MMAP};
		if xioctl(fd, VIDIOC_DQBUF, *b) < 0 {
			e := errno();
			if e == EAGAIN continue;
			if e == EIO && io_errors < 30 { io_errors += 1; sleep_milliseconds(10); continue; }
			v4l2_fail(c, "VIDIOC_DQBUF");
			break;
		}
		io_errors = 0;
		data := array_view(maps[b.index], 0, min(cast(int) b.bytesused, maps[b.index].count));
		frame: *yuv.Nv12;
		if !(b.flags & BUF_FLAG_ERROR) {
			if fmt == FOURCC_NV12 && data.count >= bpl * h * 3 / 2 frame = yuv.nv12_from_planes(w, h, data.data, data.data + bpl * h, bpl);
			else if fmt == FOURCC_YUYV && data.count >= bpl * h frame = from_yuyv(data, w, h, bpl);
			else if fmt == FOURCC_MJPG frame = from_jpeg(*jpeg, data, w, h);
		}
		xioctl(fd, VIDIOC_QBUF, *b);
		if frame { emit(c, frame); yuv.nv12_release(frame); }
	}
	return false;
}

// Logs a V4L2 call's failure and says why in c.error. Returns whether the device was busy.
v4l2_fail :: (c: *Capture, what: string) -> busy: bool {
	e := errno();
	if e != EBUSY log_error("camera: % failed (errno %)", what, e);
	c.error = ifx e == EBUSY then "The camera is in use by another app." else ifx e == ENODEV then "The camera was unplugged." else "The camera stopped.";
	return e == EBUSY;
}

// The first capture device, and its mode: at least the frame rate, then the closest height, then 16:9,
// then the cheapest format to convert. Updates camera_count.
open_camera :: (c: *Capture) -> s32, Mode {
	found, denied := 0, false;
	for i: -1..63 { // the chosen camera first, then the rest
		path := ifx i < 0 then c.device else tprint("/dev/video%", i);
		if !path || (i >= 0 && path == c.device) continue;
		fd := open(temp_c_string(path), O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if fd < 0 { if errno() == EACCES denied = true; continue; }
		cap: v4l2_capability;
		caps := ifx xioctl(fd, VIDIOC_QUERYCAP, *cap) >= 0 then (ifx cap.capabilities & CAP_DEVICE_CAPS then cap.device_caps else cap.capabilities) else 0;
		if !(caps & CAP_VIDEO_CAPTURE) || !(caps & CAP_STREAMING) { close(fd); continue; }
		found += 1;
		best: Mode;
		best_score := 1 << 62;
		fmt: v4l2_fmtdesc;
		fmt.type = BUF_TYPE_VIDEO_CAPTURE;
		while xioctl(fd, VIDIOC_ENUM_FMT, *fmt) >= 0 {
			defer fmt.index += 1;
			cost := ifx fmt.pixelformat == FOURCC_NV12 then 0 else ifx fmt.pixelformat == FOURCC_YUYV then 1 else ifx fmt.pixelformat == FOURCC_MJPG then 3 else -1;
			if cost < 0 continue;
			fs := v4l2_frmsizeenum.{pixel_format = fmt.pixelformat};
			while xioctl(fd, VIDIOC_ENUM_FRAMESIZES, *fs) >= 0 && fs.type == FRMSIZE_TYPE_DISCRETE {
				defer fs.index += 1;
				m := Mode.{fmt.pixelformat, xx fs.w, xx fs.h, 0};
				fi := v4l2_frmivalenum.{pixel_format = fmt.pixelformat, width = fs.w, height = fs.h};
				while xioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, *fi) >= 0 && fi.type == FRMIVAL_TYPE_DISCRETE {
					if fi.num m.fps = max(m.fps, cast(int) (fi.den / fi.num));
					fi.index += 1;
				}
				score := max(m.h - c.height, c.height - m.h) * 10 + cost;
				if m.fps < c.fps score += 1_000_000;
				if m.w * 9 != m.h * 16 score += 5;
				if score < best_score { best, best_score = m, score; }
			}
		}
		if best.fourcc {
			atomic_store(*camera_count, cast(s32) found);
			best.fps = min(max(best.fps, 1), c.fps);
			return fd, best;
		}
		close(fd);
	}
	atomic_store(*camera_count, cast(s32) found);
	c.error = ifx found then "The camera's video format isn't supported." else ifx denied then "fastcord isn't allowed to use the camera (add yourself to the video group)." else "No camera found.";
	return -1, .{};
}

xioctl :: (fd: s32, req: u64, arg: *void) -> s32 {
	while true {
		r := ioctl(fd, req, arg);
		if r >= 0 || errno() != EINTR return r;
	}
	return -1;
}

// YUYV (Y0 U Y1 V) -> NV12, chroma from the even rows.
from_yuyv :: (data: []u8, width: int, height: int, bpl: int) -> *yuv.Nv12 {
	f := yuv.nv12_create(width, height);
	w, h := f.width, f.height;
	uv := f.data.data + w * h;
	for y: 0..h - 1 {
		src := data.data + y * bpl;
		dst := f.data.data + y * w;
		for x: 0..w - 1 dst[x] = src[2 * x];
		if y & 1 continue;
		d := uv + (y / 2) * w;
		for x: 0..w / 2 - 1 { d[2 * x] = src[4 * x + 1]; d[2 * x + 1] = src[4 * x + 3]; }
	}
	return f;
}

Jpeg :: struct {
	state, work, rgba: []u8;
	fixed: [..]u8;
}

// MJPEG -> RGBA (Wuffs) -> NV12.
from_jpeg :: (j: *Jpeg, mjpeg: []u8, width: int, height: int) -> *yuv.Nv12 {
	data := with_huffman_tables(j, mjpeg);
	if !j.state.count j.state = NewArray(cast(int) fc_image_state_size(FC_JPEG), u8);
	info: Fc_Image_Info;
	if fc_image_open(j.state.data, xx j.state.count, FC_JPEG, data.data, xx data.count, *info) != 0 return null;
	if info.width != xx width || info.height != xx height return null;
	if j.work.count < xx info.work_len { free(j.work.data); j.work = NewArray(cast(int) info.work_len, u8); }
	if j.rgba.count < width * height * 4 { free(j.rgba.data); j.rgba = NewArray(width * height * 4, u8); }
	fi: [64]u8; // fc_frame_info
	if fc_image_next_frame(j.state.data, fi.data) != 0 return null;
	if fc_image_decode_frame(j.state.data, j.rgba.data, xx j.rgba.count, xx (width * 4), j.work.data, xx j.work.count, 1) != 0 return null;
	return nv12_from_rgb(j.rgba.data, width, height, width * 4, 4, 0, 1, 2, width, height);
}

// Many UVC cameras leave the Huffman tables out of MJPEG frames and rely on the defaults (ITU T.81 K.3):
// put them in before the first SOS when there is no DHT.
with_huffman_tables :: (j: *Jpeg, data: []u8) -> []u8 {
	i := 2;
	while i + 4 <= data.count && data[i] == 0xFF {
		m := data[i + 1];
		if m == 0xC4 return data;
		if m == 0xDA {
			j.fixed.count = 0;
			array_add(*j.fixed, ..array_view(data, 0, i));
			array_add(*j.fixed, ..DEFAULT_DHT);
			array_add(*j.fixed, ..array_view(data, i, data.count - i));
			return j.fixed;
		}
		i += 2 + ((cast(int) data[i + 2]) << 8 | data[i + 3]);
	}
	return data;
}

DEFAULT_DHT :: u8.[
	0xFF, 0xC4, 0x01, 0xA2,
	0x00, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
	0x01, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
	0x10, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D,
	0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
	0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
	0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
	0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
	0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
	0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
	0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
	0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
	0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
	0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
	0xF9, 0xFA,
	0x11, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77,
	0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
	0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
	0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
	0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
	0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
	0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
	0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
	0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
	0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
	0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
	0xF9, 0xFA,
];

// V4L2 (linux/videodev2.h, x86_64).
v4l2_capability :: struct {
	driver: [16]u8;
	card: [32]u8;
	bus_info: [32]u8;
	version, capabilities, device_caps: u32;
	reserved: [3]u32;
}
v4l2_fmtdesc :: struct {
	index, type, flags: u32;
	description: [32]u8;
	pixelformat, mbus_code: u32;
	reserved: [3]u32;
}
v4l2_frmsizeenum :: struct {
	index, pixel_format, type: u32;
	w, h: u32; // discrete; stepwise has 4 more
	stepwise_rest: [4]u32;
	reserved: [2]u32;
}
v4l2_frmivalenum :: struct {
	index, pixel_format, width, height, type: u32;
	num, den: u32; // discrete; stepwise has 4 more
	stepwise_rest: [4]u32;
	reserved: [2]u32;
}
v4l2_pix_format :: struct {
	width, height, pixelformat, field, bytesperline, sizeimage, colorspace, priv, flags, ycbcr_enc, quantization, xfer_func: u32;
}
v4l2_format :: struct {
	type: u32;
	_pad: u32; // the union is 8-aligned (it holds pointers)
	pix: v4l2_pix_format;
	_rest: [200 - size_of(v4l2_pix_format)]u8;
}
#run assert(size_of(v4l2_format) == 208);
v4l2_fract :: struct { num, den: u32; }
v4l2_streamparm :: struct {
	type: u32;
	capability, capturemode: u32;
	timeperframe: v4l2_fract;
	extendedmode, readbuffers: u32;
	_rest: [200 - 24]u8;
}
v4l2_requestbuffers :: struct {
	count, type, memory, capabilities: u32;
	flags: u8;
	reserved: [3]u8;
}
v4l2_buffer :: struct {
	index, type, bytesused, flags, field: u32;
	timestamp: [2]s64;
	timecode: [4]u32;
	sequence, memory: u32;
	offset: u32; // the union m: offset for MMAP
	_m: u32;
	length, reserved2, request_fd: u32;
}
#run assert(size_of(v4l2_buffer) == 88);

IOC :: (dir: u64, nr: u64, size: s64) -> u64 { return (dir << 30) | ((cast(u64) size) << 16) | (0x56 << 8) | nr; } // 'V'
VIDIOC_QUERYCAP :: #run IOC(2, 0, size_of(v4l2_capability));
VIDIOC_ENUM_FMT :: #run IOC(3, 2, size_of(v4l2_fmtdesc));
VIDIOC_S_FMT :: #run IOC(3, 5, size_of(v4l2_format));
VIDIOC_REQBUFS :: #run IOC(3, 8, size_of(v4l2_requestbuffers));
VIDIOC_QUERYBUF :: #run IOC(3, 9, size_of(v4l2_buffer));
VIDIOC_QBUF :: #run IOC(3, 15, size_of(v4l2_buffer));
VIDIOC_DQBUF :: #run IOC(3, 17, size_of(v4l2_buffer));
VIDIOC_STREAMON :: #run IOC(1, 18, size_of(s32));
VIDIOC_STREAMOFF :: #run IOC(1, 19, size_of(s32));
VIDIOC_S_PARM :: #run IOC(3, 22, size_of(v4l2_streamparm));
VIDIOC_ENUM_FRAMESIZES :: #run IOC(3, 74, size_of(v4l2_frmsizeenum));
VIDIOC_ENUM_FRAMEINTERVALS :: #run IOC(3, 75, size_of(v4l2_frmivalenum));

CAP_VIDEO_CAPTURE :: 0x1;
CAP_STREAMING :: 0x0400_0000;
CAP_DEVICE_CAPS :: 0x8000_0000;
BUF_TYPE_VIDEO_CAPTURE :: 1;
MEMORY_MMAP :: 1;
BUF_FLAG_ERROR :: 0x40;
FRMSIZE_TYPE_DISCRETE :: 1;
FRMIVAL_TYPE_DISCRETE :: 1;

FC_JPEG :: 3;
Fc_Image_Info :: struct { width, height: u32; work_len: u64; }
fc_image_state_size :: (format: s32) -> u64 #foreign vendor;
fc_image_open :: (state: *void, state_len: u64, format: s32, src: *u8, src_len: u64, info: *Fc_Image_Info) -> s32 #foreign vendor;
fc_image_next_frame :: (state: *void, fi: *void) -> s32 #foreign vendor;
fc_image_decode_frame :: (state: *void, canvas: *u8, canvas_len: u64, stride: u64, work: *u8, work_len: u64, replace: s32) -> s32 #foreign vendor;
