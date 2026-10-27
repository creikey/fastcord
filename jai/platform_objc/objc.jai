// Minimal Objective-C messaging: each call casts objc_msgSend to the exact C prototype, so
// struct/float ABI is right.
//
//	r := objc.msg(objc.Id, obj, "objectAtIndex:", cast(u64) 0);
//	objc.msg(objc.Void, view, "setNeedsDisplay:", true);
Id :: *void;
SEL :: *void;
Void :: struct {}

#scope_module
objc_msgSend :: () #foreign lib;
sel_registerName :: (name: *u8) -> SEL #foreign lib;
objc_lookUpClass :: (name: *u8) -> Id #foreign lib;
objc_allocateClassPair :: (superclass: Id, name: *u8, extraBytes: u64) -> Id #foreign lib;
objc_registerClassPair :: (cls: Id) #foreign lib;
class_addMethod :: (cls: Id, name: SEL, imp: *void, types: *u8) -> bool #foreign lib;
#if CPU == .X64 {
	objc_msgSend_stret :: () #foreign lib;
	STRET :: true;
} else {
	STRET :: false;
	objc_msgSend_stret :: objc_msgSend;
}
#scope_export

class_getMethodImplementation :: (c: Id, s: SEL) -> *void #foreign lib;
objc_getProtocol :: (name: *u8) -> *void #foreign lib;
class_addProtocol :: (c: Id, p: *void) -> bool #foreign lib;

allocate_class :: (super: Id, name: *u8) -> Id #no_context { return objc_allocateClassPair(super, name, 0); }
register_class :: (c: Id) #no_context { objc_registerClassPair(c); }
add_method :: (c: Id, name: *u8, imp: *void, types: *u8) -> bool #no_context {
	return class_addMethod(c, sel_registerName(name), imp, types);
}

cls :: inline (name: *u8) -> Id #no_context { return objc_lookUpClass(name); }
sel :: inline (name: *u8) -> SEL #no_context { return sel_registerName(name); }

// Objects allocated with alloc/init and autorelease pools.
new_obj :: (class_name: *u8) -> Id #no_context {
	return msg(Id, msg(Id, cls(class_name), "alloc"), "init");
}

// msg(R, o, selector, args...) sends with 0 to 10 arguments; R = Void for no result.

msg :: inline ($R: Type, o: Id, s: *u8) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL) #c_call) cast(*void) objc_msgSend)(o, sel(s));
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s));
		return r;
	} else {
		return (cast(#type (Id, SEL) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s));
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0);
		return r;
	} else {
		return (cast(#type (Id, SEL, A) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E, F) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E, F) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4, a5);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E, F) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E, F, G) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E, F, G) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E, F, G) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E, F, G, H) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E, F, G, H) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E, F, G, H) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E, F, G, H, I) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E, F, G, H, I) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E, F, G, H, I) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
	}
}

msg :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I, a9: $J) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL, A, B, C, D, E, F, G, H, I, J) #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL, A, B, C, D, E, F, G, H, I, J) #c_call) cast(*void) objc_msgSend_stret)(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
		return r;
	} else {
		return (cast(#type (Id, SEL, A, B, C, D, E, F, G, H, I, J) -> R #c_call) cast(*void) objc_msgSend)(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
	}
}
