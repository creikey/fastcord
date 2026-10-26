#+build darwin
// Minimal Objective-C messaging without intrinsics.objc_send (which crashes
// this Odin compiler build: "missing procedure objc_lookUpClass"). Each call
// casts objc_msgSend to the exact C prototype, so struct/float ABI is right.
//
//	r := objc.msg(objc.Id, obj, "objectAtIndex:", uint(0))
//	objc.msg(objc.Void, view, "setNeedsDisplay:", true)
package objc

Id :: distinct rawptr
SEL :: distinct rawptr
Void :: struct {}

import "base:intrinsics"

foreign import lib "system:objc"
@(require) foreign import "system:Foundation.framework"

// Signatures of symbols also declared by base:runtime must match it exactly.
@(private)
_IMP :: proc "c" (object: ^intrinsics.objc_object, sel: ^intrinsics.objc_selector, #c_vararg args: ..any) -> ^intrinsics.objc_object

@(private, default_calling_convention = "c")
foreign lib {
	objc_msgSend :: proc(self: ^intrinsics.objc_object, op: ^intrinsics.objc_selector, #c_vararg args: ..any) ---
	sel_registerName :: proc(name: cstring) -> ^intrinsics.objc_selector ---
	objc_lookUpClass :: proc(name: cstring) -> ^intrinsics.objc_class ---
	objc_allocateClassPair :: proc(superclass: ^intrinsics.objc_class, name: cstring, extraBytes: uint) -> ^intrinsics.objc_class ---
	objc_registerClassPair :: proc(cls: ^intrinsics.objc_class) ---
	class_addMethod :: proc(cls: ^intrinsics.objc_class, name: ^intrinsics.objc_selector, imp: _IMP, types: cstring) -> bool ---
}

@(default_calling_convention = "c")
foreign lib {
	class_getMethodImplementation :: proc(c: Id, s: SEL) -> rawptr ---
	objc_getProtocol :: proc(name: cstring) -> rawptr ---
	class_addProtocol :: proc(c: Id, p: rawptr) -> bool ---
}

allocate_class :: proc "contextless" (super: Id, name: cstring) -> Id {
	return Id(objc_allocateClassPair((^intrinsics.objc_class)(super), name, 0))
}
register_class :: proc "contextless" (c: Id) {objc_registerClassPair((^intrinsics.objc_class)(c))}
add_method :: proc "contextless" (c: Id, name: cstring, imp: rawptr, types: cstring) -> bool {
	return class_addMethod((^intrinsics.objc_class)(c), sel_registerName(name), cast(_IMP)imp, types)
}

when ODIN_ARCH == .amd64 {
	@(default_calling_convention = "c")
	foreign lib {
		objc_msgSend_stret :: proc() ---
	}
	@(private) STRET :: true
} else {
	@(private)
	STRET :: false
	@(private)
	objc_msgSend_stret := objc_msgSend
}

cls :: #force_inline proc "contextless" (name: cstring) -> Id {return Id(objc_lookUpClass(name))}
sel :: #force_inline proc "contextless" (name: cstring) -> SEL {return SEL(sel_registerName(name))}

// Objects allocated with alloc/init and autorelease pools.
new_obj :: proc "contextless" (class_name: cstring) -> Id {
	return msg(Id, msg(Id, cls(class_name), "alloc"), "init")
}

msg0 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL))rawptr(objc_msgSend))(o, sel(s))
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL))rawptr(objc_msgSend_stret))(&r, o, sel(s))
		return r
	} else {
		return (cast(proc "c" (Id, SEL) -> R)rawptr(objc_msgSend))(o, sel(s))
	}
}

msg1 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A))rawptr(objc_msgSend))(o, sel(s), a0)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A) -> R)rawptr(objc_msgSend))(o, sel(s), a0)
	}
}

msg2 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B))rawptr(objc_msgSend))(o, sel(s), a0, a1)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1)
	}
}

msg3 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2)
	}
}

msg4 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3)
	}
}

msg5 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4)
	}
}

msg6 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E, F))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E, F))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4, a5)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E, F) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5)
	}
}

msg7 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E, F, G))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E, F, G))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4, a5, a6)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E, F, G) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6)
	}
}

msg8 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E, F, G, H))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7)
	}
}

msg9 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H, I))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E, F, G, H, I))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H, I) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8)
	}
}

msg10 :: #force_inline proc "contextless" ($R: typeid, o: Id, s: cstring, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I, a9: $J) -> R {
	when R == Void {
		(cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H, I, J))rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		return {}
	} else when STRET && size_of(R) > 16 {
		r: R
		(cast(proc "c" (^R, Id, SEL, A, B, C, D, E, F, G, H, I, J))rawptr(objc_msgSend_stret))(&r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9)
		return r
	} else {
		return (cast(proc "c" (Id, SEL, A, B, C, D, E, F, G, H, I, J) -> R)rawptr(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9)
	}
}

msg :: proc {msg0, msg1, msg2, msg3, msg4, msg5, msg6, msg7, msg8, msg9, msg10}
