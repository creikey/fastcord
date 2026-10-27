#import "Basic";
#import "fc";
print_string :: (s: string) { write_string(s, to_standard_error = true); }
print_int :: (i: int) { print_string(tprint("%", i)); }
print_caller_location :: (loc: Source_Code_Location) { print_string(tprint("%:%:%", loc.fully_pathed_filename, loc.line_number, loc.character_number)); }
panic_contextless :: (msg: string, loc := #caller_location) { assert(false, "%", msg, loc = loc); }
DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD :: () #expand { auto_release_temp(); }
