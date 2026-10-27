// Other threads' stacks need ptrace (another process); gdb gives them without code here.
write_thread_stacks :: (b: *String_Builder, main_tid: int) {
	print_to_builder(b, "for every thread's stack run: gdb -p % -batch -ex 'thread apply all bt'\n", getpid());
}

#scope_file

getpid :: () -> s32 #foreign libc;
