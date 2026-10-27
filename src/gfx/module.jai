#import "Basic";
#import "Math";
#import "String";
#import "Hash_Table";
#import "Hash";
#import "Sort";
#import "File";
#import "Unicode";
platform :: #import "platform";

#if OS == .MACOS {
    objc :: #import "platform_objc";
    Metal :: #library,system,link_always "Metal";
    CoreFoundation :: #library,system,link_always "CoreFoundation";
    CoreText :: #library,system,link_always "CoreText";
    CoreGraphics :: #library,system,link_always "CoreGraphics";
    #load "backend_metal_darwin.jai";
    #load "text_coretext_darwin.jai";
}
#if OS == .WINDOWS {
    #import "Windows";
    #import "Windows_Utf8";
    #import "d3d11";
    #import "dxgi";
    #import "d3d_compiler";
    prof :: #import "prof";
    dwrite :: #system_library "dwrite";
    #load "backend_d3d11_windows.jai";
    #load "text_dwrite_windows.jai";
}
#load "gfx.jai";
#load "shaders.jai";
#load "text.jai";
#load "util.jai";

#scope_module

// Odin's [2]f32 / [4]f32 are Math's Vector2 / Vector4. Math's `v / k` multiplies by 1/k, which changes
// pixels; this module's own operator divides per component like Odin (module scope wins over Math's).
operator / :: (a: Vector2, k: float32) -> Vector2 { return .{a.x / k, a.y / k}; }

// Odin's math.round: halves away from zero.
round :: inline (x: float32) -> float32 { return ifx x < 0 then -floor(-x + 0.5) else floor(x + 0.5); }
