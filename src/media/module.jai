#import "Basic";
#import "Math";
#import "String";
#import "Hash_Table";
#import "Thread";
#import "File";
audio :: #import "audio";
gfx :: #import "gfx";
locks :: #import "locks";
opus :: #import "opus";
#if OS == .MACOS {
	CoreFoundation :: #library,system,link_always "CoreFoundation";
	CoreMedia :: #library,system,link_always "CoreMedia";
	CoreVideo :: #library,system,link_always "CoreVideo";
	VideoToolbox :: #library,system,link_always "VideoToolbox";
	AudioToolbox :: #library,system,link_always "AudioToolbox";
	#load "decode_darwin.jai";
}
#if OS == .WINDOWS #load "decode_windows.jai";
#if OS == .LINUX #load "decode_linux.jai";
#if OS != .MACOS {
	yuv :: #import "yuv";
	#load "frame_nv12.jai";
	#load "decode_none.jai";
}
#load "decode_sw.jai";
#load "demux.jai";
#load "mkv.jai";
#load "mp4.jai";
#load "ogg.jai";
#load "player.jai";
#load "probe.jai";
#load "simple_formats.jai";
#load "source.jai";
#load "sound.jai";
