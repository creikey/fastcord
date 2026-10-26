package app

import "core:fmt"
import "core:os"
import "core:strings"

// Other threads' stacks need Mach thread APIs; `sample` gives them without code here.
write_thread_stacks :: proc(b: ^strings.Builder, main_tid: int) {
	fmt.sbprintfln(b, "for every thread's stack run: sample %d 1", os.get_pid())
}
