#import "Basic";
#import "fc";
#import "System";
S :: #import "String";
join :: (parts: []string, allocator := context.allocator) -> string, *void {
    push_allocator(allocator);
    nonempty: [..]string; nonempty.allocator = temp;
    for parts if it.count array_add(*nonempty, it);
    return S.join(..nonempty, separator = "/"), null;
}
base :: (p: string) -> string { i := S.find_index_from_right(p, #char "/"); return ifx i < 0 then p else sub_from(p, i + 1); }
dir :: (p: string, allocator := context.allocator) -> string { i := S.find_index_from_right(p, #char "/"); push_allocator(allocator); return copy_string(ifx i < 0 then "." else ifx i == 0 then "/" else sub(p, 0, i)); }
ext :: (p: string) -> string { b := base(p); i := S.find_index_from_right(b, #char "."); return ifx i < 0 then "" else sub_from(b, i); }
stem :: (p: string) -> string { b := base(p); e := ext(b); return sub(b, 0, b.count - e.count); }
abs :: (p: string, allocator := context.allocator) -> string, bool {
    push_allocator(allocator);
    if p.count && p[0] == #char "/" return copy_string(p), true;
    return tprint("%/%", get_working_directory(), p), true;
}
