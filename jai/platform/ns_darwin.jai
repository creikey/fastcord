// The Foundation / CoreVideo types and globals platform uses (Odin's core:sys/darwin/Foundation, vendor:darwin/CoreVideo).
NS :: struct {
	UInteger :: u64;
	Integer :: s64;
	IntegerMax :: 0x7fff_ffff_ffff_ffff;
	BOOL :: bool;
	Float :: float64;
	TimeInterval :: float64;
	EventMaskAny : u64 : 0xffff_ffff_ffff_ffff;
	Point :: struct { x, y: Float; }
	Size :: struct { width, height: Float; }
	Rect :: struct { origin: Point; size: Size; }
	Range :: struct { location, length: UInteger; }
}

NSDefaultRunLoopMode: Id #elsewhere __lib__t1;
NSRunLoopCommonModes: Id #elsewhere __lib__t1;

CVDisplayLinkRef :: *void;
CV :: struct {
	Return :: s32;
	OptionFlags :: u64;
	TimeStamp :: struct {
		version: u32;
		videoTimeScale: s32;
		videoTime: s64;
		hostTime: u64;
		rateScalar: float64;
		videoRefreshPeriod: s64;
		smpteTime: [24]u8;
		flags: u64;
		reserved: u64;
	}
}
CVDisplayLinkCreateWithActiveCGDisplays :: (link: *CVDisplayLinkRef) -> CV.Return #foreign corevideo;
CVDisplayLinkSetOutputCallback :: (link: CVDisplayLinkRef, cb: *void, user: *void) -> CV.Return #foreign corevideo;
CVDisplayLinkStart :: (link: CVDisplayLinkRef) -> CV.Return #foreign corevideo;
CVDisplayLinkStop :: (link: CVDisplayLinkRef) -> CV.Return #foreign corevideo;
CVDisplayLinkRelease :: (link: CVDisplayLinkRef) #foreign corevideo;
corevideo :: #library,system,link_always "CoreVideo";
