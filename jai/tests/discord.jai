// Offline parity tests of the discord module (jai build.jai - test): replay traffic/<scenario>.jsonl, no network.
// Arguments: substrings of test names to run (all by default). Run from the repo root.
#import "Basic";
#import "fc";
discord :: #import "discord"(TESTS = true);
main :: () {
	register_thread_context();
    args := get_command_line_arguments();
    failed := discord.run_tests(array_view(args, 1));
    print("% failed\n", failed);
    exit(xx ifx failed then 1 else 0);
}
