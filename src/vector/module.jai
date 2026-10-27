#import "Basic";
#import "String";
#import "Hash_Table";
#import "Flat_Pool";
#import "Math";
#load "vector.jai";
#load "gradient.jai";
#load "parse.jai";
#load "raster.jai";
#load "xml.jai";

#scope_module

// Odin's [2]f32 / [4]f32 are Math's Vector2 / Vector4. Math's `v / k` multiplies by 1/k, which changes
// pixels; this module's own operator divides per component like Odin (module scope wins over Math's).
operator / :: (a: Vector2, k: float32) -> Vector2 { return .{a.x / k, a.y / k}; }
operator / :: (a: Vector4, k: float32) -> Vector4 { return .{a.x / k, a.y / k, a.z / k, a.w / k}; }
operator *[] :: (v: *Vector2, i: int) -> *float32 { return *v.component[i]; }
operator *[] :: (v: *Vector4, i: int) -> *float32 { return *v.component[i]; }
