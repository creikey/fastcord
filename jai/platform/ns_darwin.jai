// The Foundation / CoreGraphics / CoreVideo types and globals platform uses.
#scope_module

msg :: objc.msg;
cls :: objc.cls;
sel :: objc.sel;
Id :: objc.Id;
SEL :: objc.SEL;
Void :: objc.Void;

NSUInteger :: u64;
NSInteger :: s64;
NSFloat :: float64;
NSPoint :: struct { x, y: NSFloat; }
NSSize :: struct { width, height: NSFloat; }
NSRect :: struct { origin: NSPoint; size: NSSize; }
NSRange :: struct { location, length: NSUInteger; }
NS_NOT_FOUND :: cast(NSUInteger) 0x7fff_ffff_ffff_ffff;
NS_EVENT_MASK_ANY :: 0xffff_ffff_ffff_ffff;

cocoa :: #library,system,link_always "Cocoa";
quartz_core :: #library,system,link_always "QuartzCore";
core_graphics :: #library,system,link_always "CoreGraphics";
core_video :: #library,system,link_always "CoreVideo";

NSDefaultRunLoopMode: Id #elsewhere cocoa;
NSRunLoopCommonModes: Id #elsewhere cocoa;

kCGColorSpaceSRGB: *void #elsewhere core_graphics; // CFStringRef
CGColorSpaceCreateWithName :: (name: *void) -> *void #foreign core_graphics;
CGColorSpaceRelease :: (cs: *void) #foreign core_graphics;

CVDisplayLinkRef :: *void;
CVTimeStamp :: struct {
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
CVDisplayLinkCreateWithActiveCGDisplays :: (link: *CVDisplayLinkRef) -> s32 #foreign core_video;
CVDisplayLinkSetOutputCallback :: (link: CVDisplayLinkRef, cb: *void, user: *void) -> s32 #foreign core_video;
CVDisplayLinkStart :: (link: CVDisplayLinkRef) -> s32 #foreign core_video;
CVDisplayLinkStop :: (link: CVDisplayLinkRef) -> s32 #foreign core_video;
CVDisplayLinkRelease :: (link: CVDisplayLinkRef) #foreign core_video;

// A copied, autoreleased NSString.
nsstr :: (str: string) -> Id {
    s0 := msg(Id, cls("NSString"), "alloc");
    s1 := msg(Id, s0, "initWithBytes:length:encoding:", str.data, cast(NSUInteger) str.count, cast(NSUInteger) 4 /*UTF8*/);
    return msg(Id, s1, "autorelease");
}

// An NSString's UTF-8 copy.
to_jai_string :: (nss: Id, allocator: Allocator) -> string {
    if !nss return "";
    c := msg(*u8, nss, "UTF8String");
    if !c return "";
    return copy_string(to_string(c),, allocator);
}

autorelease_pool :: () -> Id { return objc.new_obj("NSAutoreleasePool"); }
