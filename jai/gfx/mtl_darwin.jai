// The Metal enums and C function the backend uses (Odin's vendor:darwin/Metal).
MTL :: struct {
	PixelFormat :: enum u64 { R8Unorm :: 10; RG8Unorm :: 30; RGBA8Unorm :: 70; BGRA8Unorm :: 80; }
	BlendFactor :: enum u64 { One :: 1; OneMinusSourceAlpha :: 5; }
	LoadAction :: enum u64 { Clear :: 2; }
	StoreAction :: enum u64 { Store :: 1; }
	PrimitiveType :: enum u64 { TriangleStrip :: 4; }
	StorageMode :: enum u64 { Shared :: 0; Managed :: 1; Private :: 2; }
	TextureUsage :: enum_flags u64 { ShaderRead :: 1; ShaderWrite :: 2; RenderTarget :: 4; }
	ClearColor :: struct { r, g, b, a: float64; }
}
MTLCreateSystemDefaultDevice :: () -> *void #foreign __lib__t1;
CFStringGetCString :: (s: *void, buf: *u8, n: s64, encoding: u32) -> bool #foreign CoreFoundation;
