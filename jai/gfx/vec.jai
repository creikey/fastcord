// Odin's [2]f32 / [4]f32 are Jai Math's Vector2 / Vector4 (fc exports Math named: it can't be imported
// unnamed next to fc, so the arithmetic is declared here). ui/gfx/platform each carry this same file.
Vector2 :: Math.Vector2;
Vector4 :: Math.Vector4;
operator + :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x + b.x, a.y + b.y}; }
operator - :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x - b.x, a.y - b.y}; }
operator - :: (a: Vector2) -> Vector2 { return .{-a.x, -a.y}; }
operator * :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x * b.x, a.y * b.y}; }
operator * :: (a: Vector2, t: float32) -> Vector2 #symmetric { return .{a.x * t, a.y * t}; }
operator / :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x / b.x, a.y / b.y}; }
operator / :: (a: Vector2, t: float32) -> Vector2 { return .{a.x / t, a.y / t}; }
operator == :: (a: Vector2, b: Vector2) -> bool { return a.x == b.x && a.y == b.y; }
operator + :: (a: Vector4, b: Vector4) -> Vector4 { return .{a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w}; }
operator - :: (a: Vector4, b: Vector4) -> Vector4 { return .{a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w}; }
operator * :: (a: Vector4, b: Vector4) -> Vector4 { return .{a.x * b.x, a.y * b.y, a.z * b.z, a.w * b.w}; }
operator * :: (a: Vector4, t: float32) -> Vector4 #symmetric { return .{a.x * t, a.y * t, a.z * t, a.w * t}; }
operator / :: (a: Vector4, t: float32) -> Vector4 { return .{a.x / t, a.y / t, a.z / t, a.w / t}; }
operator == :: (a: Vector4, b: Vector4) -> bool { return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w; }
