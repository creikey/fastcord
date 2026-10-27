// Math's Vector2 / Vector4 `/` multiplies by the reciprocal, which would change pixels; these divide per
// component (module scope wins over Math's).
operator / :: (a: Vector2, b: Vector2) -> Vector2 { return .{a.x / b.x, a.y / b.y}; }
operator / :: (a: Vector2, t: float32) -> Vector2 { return .{a.x / t, a.y / t}; }
operator / :: (a: Vector4, t: float32) -> Vector4 { return .{a.x / t, a.y / t, a.z / t, a.w / t}; }
