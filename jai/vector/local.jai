// Odin's [2]f32 / [4]f32 are Math's Vector2 / Vector4 here. Math's own operators are not imported:
// its `v / k` multiplies by 1/k, which changes pixels; these divide per component like Odin.
M :: #import "Math";
Vector2 :: M.Vector2;
Vector4 :: M.Vector4;
#scope_module
operator *[] :: (v: *Vector2, i: int) -> *float32 { return *v.component[i]; }
operator *[] :: (v: *Vector4, i: int) -> *float32 { return *v.component[i]; }
operator + :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x + b.x, a.y + b.y}; }
operator - :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x - b.x, a.y - b.y}; }
operator - :: (a: Vector2) -> Vector2 { return .{-a.x, -a.y}; }
operator * :: (a: Vector2, k: float32) -> Vector2 #symmetric { return .{a.x * k, a.y * k}; }
operator / :: (a: Vector2, k: float32) -> Vector2 { return .{a.x / k, a.y / k}; }
operator == :: (a: Vector2, b: Vector2) -> bool { return a.x == b.x && a.y == b.y; }
operator + :: (a: Vector4, b: Vector4) -> Vector4 { return .{a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w}; }
operator - :: (a: Vector4, b: Vector4) -> Vector4 { return .{a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w}; }
operator * :: (a: Vector4, k: float32) -> Vector4 #symmetric { return .{a.x * k, a.y * k, a.z * k, a.w * k}; }
operator / :: (a: Vector4, k: float32) -> Vector4 { return .{a.x / k, a.y / k, a.z / k, a.w / k}; }
// Odin's untyped math.PI in f32 expressions.
PI32 :: cast(float32) math.PI;
