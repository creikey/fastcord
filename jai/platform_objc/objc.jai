Id :: *void;
SEL :: *void;
Void :: struct {}


#scope_module

// Signatures of symbols also declared by base:runtime must match it exactly.
_IMP :: (object: *intrinsics.objc_object, sel: *intrinsics.objc_selector, args: ..Any) -> *intrinsics.objc_object #c_call;
	objc_msgSend :: (self: *intrinsics.objc_object, op: *intrinsics.objc_selector, args: ..Any) #foreign lib;
	sel_registerName :: (name: *u8) -> *intrinsics.objc_selector #foreign lib;
	objc_lookUpClass :: (name: *u8) -> *intrinsics.objc_class #foreign lib;
	objc_allocateClassPair :: (superclass: *intrinsics.objc_class, name: *u8, extraBytes: u64) -> *intrinsics.objc_class #foreign lib;
	objc_registerClassPair :: (cls: *intrinsics.objc_class) #foreign lib;
	class_addMethod :: (cls: *intrinsics.objc_class, name: *intrinsics.objc_selector, imp: _IMP, types: *u8) -> bool #foreign lib;
#scope_export
	class_getMethodImplementation :: (c: Id, s: SEL) -> *void #foreign lib;
	objc_getProtocol :: (name: *u8) -> *void #foreign lib;
	class_addProtocol :: (c: Id, p: *void) -> bool #foreign lib;

allocate_class :: (super: Id, name: *u8) -> Id #no_context {
	return cast(Id)(objc_allocateClassPair(cast(*intrinsics.objc_class)(super), name, 0));
}
register_class :: (c: Id) #no_context {objc_registerClassPair(cast(*intrinsics.objc_class)(c));}
add_method :: (c: Id, name: *u8, imp: *void, types: *u8) -> bool #no_context {
	return class_addMethod(cast(*intrinsics.objc_class)(c), sel_registerName(name), cast(_IMP)imp, types);
}

#if CPU == .X64 {
		objc_msgSend_stret :: (self: *intrinsics.objc_object, op: *intrinsics.objc_selector, args: ..Any) #foreign lib;
#scope_module
	STRET :: true;
#scope_export
} else {
#scope_module
	STRET :: false;
	objc_msgSend_stret := objc_msgSend;
#scope_export
}

cls :: inline (name: *u8) -> Id #no_context {return cast(Id)(objc_lookUpClass(name));};
sel :: inline (name: *u8) -> SEL #no_context {return cast(SEL)(sel_registerName(name));};

// Objects allocated with alloc/init and autorelease pools.
new_obj :: (class_name: *u8) -> Id #no_context {
	return msg(Id, msg(Id, cls(class_name), "alloc"), "init");
}

msg0 :: inline ($R: Type, o: Id, s: *u8) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL) #c_call)cast(*void)(objc_msgSend))(o, sel(s));
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s));
		return r;
	} else {
		return (cast((Id, SEL) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s));
	}
};

msg1 :: inline ($R: Type, o: Id, s: *u8, a0: $A) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0);
		return r;
	} else {
		return (cast((Id, SEL, A) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0);
	}
};

msg2 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A, B) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A, B) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1);
		return r;
	} else {
		return (cast((Id, SEL, A, B) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1);
	}
};

msg3 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A, B, C) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A, B, C) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2);
		return r;
	} else {
		return (cast((Id, SEL, A, B, C) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2);
	}
};

msg4 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A, B, C, D) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A, B, C, D) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3);
		return r;
	} else {
		return (cast((Id, SEL, A, B, C, D) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3);
	}
};

msg5 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A, B, C, D, E) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A, B, C, D, E) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4);
		return r;
	} else {
		return (cast((Id, SEL, A, B, C, D, E) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4);
	}
};

msg6 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, A, B, C, D, E, F) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, A, B, C, D, E, F) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4, a5);
		return r;
	} else {
		return (cast((Id, SEL, A, B, C, D, E, F) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5);
	}
};

msg7 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, G, A, B, C, D, E, F) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, G, A, B, C, D, E, F) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6);
		return r;
	} else {
		return (cast((Id, SEL, G, A, B, C, D, E, F) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6);
	}
};

msg8 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, G, A, B, C, D, E, F, H) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, G, A, B, C, D, E, F, H) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
		return r;
	} else {
		return (cast((Id, SEL, G, A, B, C, D, E, F, H) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7);
	}
};

msg9 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, G, A, B, C, D, E, F, H, I) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, G, A, B, C, D, E, F, H, I) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
		return r;
	} else {
		return (cast((Id, SEL, G, A, B, C, D, E, F, H, I) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8);
	}
};

msg10 :: inline ($R: Type, o: Id, s: *u8, a0: $A, a1: $B, a2: $C, a3: $D, a4: $E, a5: $F, a6: $G, a7: $H, a8: $I, a9: $J) -> R #no_context {
	#if R == Void {
		(cast((Id, SEL, G, A, B, C, D, E, F, H, I, J) #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast((*R, Id, SEL, G, A, B, C, D, E, F, H, I, J) #c_call)cast(*void)(objc_msgSend_stret))(*r, o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
		return r;
	} else {
		return (cast((Id, SEL, G, A, B, C, D, E, F, H, I, J) -> R #c_call)cast(*void)(objc_msgSend))(o, sel(s), a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
	}
};

