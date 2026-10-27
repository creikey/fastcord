// Other threads' stacks need Mach thread APIs; `sample` gives them without code here.
write_thread_stacks :: (b: *String_Builder, main_tid: int) {
	print_to_builder(b, "for every thread's stack run: sample % 1\n", getpid());
}

#scope_file

getpid :: () -> s32 #foreign libc;
