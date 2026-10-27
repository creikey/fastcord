// Minimal Objective-C messaging: each call casts objc_msgSend to the exact C prototype, so
// struct/float ABI is right.
//
//	r := objc.msg(objc.Id, obj, "objectAtIndex:", cast(u64) 0);
//	objc.msg(objc.Void, view, "setNeedsDisplay:", true);
Id :: *void;
SEL :: *void;
Void :: struct {}

class_getMethodImplementation :: (c: Id, s: SEL) -> *void #foreign libobjc;
objc_getProtocol :: (name: *u8) -> *void #foreign libobjc;
class_addProtocol :: (c: Id, p: *void) -> bool #foreign libobjc;

allocate_class :: (super: Id, name: *u8) -> Id #no_context { return objc_allocateClassPair(super, name, 0); }
register_class :: (c: Id) #no_context { objc_registerClassPair(c); }
add_method :: (c: Id, name: *u8, imp: *void, types: *u8) -> bool #no_context {
	return class_addMethod(c, sel_registerName(name), imp, types);
}

cls :: inline (name: *u8) -> Id #no_context { return objc_lookUpClass(name); }
sel :: inline (name: *u8) -> SEL #no_context { return sel_registerName(name); }

// An object allocated with alloc/init.
new_obj :: (class_name: *u8) -> Id #no_context {
	return msg(Id, msg(Id, cls(class_name), "alloc"), "init");
}

// msg(R, o, selector, args...) sends with 0 to 10 arguments; R = Void for no result.
// One overload per argument count, generated:
//	msg :: inline ($R: Type, o: Id, s: *u8, a0: $A0, ...) -> R #no_context
#insert #run -> string {
	b: String_Builder;
	for n: 0..10 {
		params, types, args: String_Builder;
		for 0..n-1 {
			print_to_builder(*params, ", a%1: $A%1", it);
			print_to_builder(*types, ", A%", it);
			print_to_builder(*args, ", a%", it);
		}
		p, t, a := builder_to_string(*params), builder_to_string(*types), builder_to_string(*args);
		print_to_builder(*b, #string DONE
msg :: inline ($R: Type, o: Id, s: *u8%1) -> R #no_context {
	#if R == Void {
		(cast(#type (Id, SEL%2) #c_call) cast(*void) objc.objc_msgSend)(o, sel(s)%3);
		return .{};
	} else #if STRET && size_of(R) > 16 {
		r: R;
		(cast(#type (*R, Id, SEL%2) #c_call) cast(*void) objc.objc_msgSend_stret)(*r, o, sel(s)%3);
		return r;
	} else {
		return (cast(#type (Id, SEL%2) -> R #c_call) cast(*void) objc.objc_msgSend)(o, sel(s)%3);
	}
}
DONE, p, t, a);
	}
	return builder_to_string(*b);
};

#scope_module

#import "Basic";
libobjc :: #system_library "libobjc";
Foundation :: #library,system,link_always "Foundation";

// objc_msgSend comes from Jai's Objective_C module (System imports it anyway): a second #foreign declaration
// of the same symbol must have the same type, and its x64 bindings type it.
objc :: #import "Objective_C";
sel_registerName :: (name: *u8) -> SEL #foreign libobjc;
objc_lookUpClass :: (name: *u8) -> Id #foreign libobjc;
objc_allocateClassPair :: (superclass: Id, name: *u8, extraBytes: u64) -> Id #foreign libobjc;
objc_registerClassPair :: (cls: Id) #foreign libobjc;
class_addMethod :: (cls: Id, name: SEL, imp: *void, types: *u8) -> bool #foreign libobjc;
STRET :: CPU == .X64;
