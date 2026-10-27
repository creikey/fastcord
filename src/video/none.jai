// Windows and Linux: not implemented yet; everything reports unsupported.

Capture :: struct {}
Encoder :: struct {}

camera_supported :: () -> bool { return false; }
camera_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30) -> *Capture { return null; }
screen_supported :: () -> bool { return false; }
screen_targets_refresh :: () {}
screen_targets :: () -> []Screen_Target, ready: bool { return .[], false; }
screen_start :: (target: Screen_Target, on_frame: Frame_Proc, user: *void, fps := 30, max_height := 1080) -> *Capture { return null; }
capture_stop :: (c: *Capture) {}

encoder_supported :: (codec: Video_Codec) -> bool { return false; }
encoder_create :: (codec: Video_Codec, width: int, height: int, fps: int, bitrate: int, on_output: Encoded_Proc, user: *void) -> *Encoder { return null; }
encoder_encode :: (e: *Encoder, pixbuf: *void, pts_90k: u32, force_keyframe := false) {}
encoder_destroy :: (e: *Encoder) {}
pattern_start :: (on_frame: Frame_Proc, user: *void, width := 1280, height := 720, fps := 30) -> *Capture { return null; }
