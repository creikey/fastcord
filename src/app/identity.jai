// The identity keypairs (src/keys): loaded, or the first one made, on a thread at startup, since
// SLH-DSA key generation and DPAPI are too slow for the UI thread.

Identity_State :: struct {
	list: [..]keys.Keypair; // The loader thread's until done is set, then the UI thread's.
	done: s32;
}
idk: Identity_State;

identity_start :: () {
	dc.spawn(*idk, (s: *Identity_State) {
		dir := app_data_dir("keys");
		s.list = keys.load(dir);
		if s.list.count == 0 {
			k := keys.generate("Default");
			if !keys.save(dir, k) log_error("keys: cannot save a new keypair in %", dir);
			array_add(*s.list, k);
		}
		atomic_swap(*s.done, 1);
		platform.request_frame();
	});
}
