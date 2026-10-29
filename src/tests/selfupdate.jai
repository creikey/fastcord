// Self-update check: jai build.jai - run src/tests/selfupdate.jai, then build/selfupdate. The manifest's
// signature rules, and install's swap on a fake app under build/selfupdate_test (packed with the OS's own
// archiver, as release.yml's archives are).
#import "Basic";
#import "File";
#import "File_Utilities";
#import "String";
#import "Process";
crypto :: #import "crypto";
su :: #import "selfupdate";
#if OS == .WINDOWS {
	msvcprt :: #library,system,no_dll,link_always "msvcprt";
	ws2_32 :: #library,system,link_always "ws2_32"; // BoringSSL's socket BIOs come in with the AEADs.
}

hexs :: (b: []u8) -> string {
	s: String_Builder;
	for b print_to_builder(*s, "%", formatInt(it, base = 16, minimum_digits = 2));
	return builder_to_string(*s,, temp);
}

main :: () {
	failed := 0;
	check :: (ok: bool, what: string) #expand {
		if !ok { print("FAIL: %\n", what); `failed += 1; }
	}

	priv, pub := crypto.ed25519_generate();
	key := hexs(pub);
	archive_hash := crypto.sha256(xx "archive bytes");
	manifest := tprint("fastcord-update v1.2.3\n%  fastcord-plan9.zip\n%  %\n", hexs(crypto.sha256(xx "other")), hexs(archive_hash), su.ASSET);
	sig_bytes := crypto.ed25519_sign(priv, xx manifest);
	sig: []u8 = sig_bytes;
	h, ok := su.manifest_hash(manifest, sig, "v1.2.3", key = key);
	check(ok && crypto.constant_time_equal(h, archive_hash), "signed manifest gives the asset's hash");
	_, ok = su.manifest_hash(manifest, sig, "v1.2.4", key = key);
	check(!ok, "another tag is refused");
	_, ok = su.manifest_hash(manifest, sig, "v1.2.3", asset = "fastcord-freebsd.zip", key = key);
	check(!ok, "an asset the manifest doesn't list is refused");
	_, ok = su.manifest_hash(manifest, sig, "v1.2.3");
	check(!ok, "the pinned release key doesn't accept the test key's signature");
	tampered := copy_string(manifest,, temp);
	tampered[30] ^= 1;
	_, ok = su.manifest_hash(tampered, sig, "v1.2.3", key = key);
	check(!ok, "a changed manifest is refused");
	sig[0] ^= 1;
	_, ok = su.manifest_hash(manifest, sig, "v1.2.3", key = key);
	check(!ok, "a changed signature is refused");

	// A manifest as release.yml makes it (sha256sum, then `openssl pkeyutl -sign -rawin` with the release key):
	// the pinned key must accept it.
	release_manifest := #string END
fastcord-update v0.0.0
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  fastcord-macos.zip
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  fastcord-windows.zip
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  fastcord-linux-x86_64.tar.gz
END
	release_sig :: "0d2019756025120540bdf13bd77386da9af5e5cd0219d696d164633fa144cc7d78a49578b517afc7068a36251a71057a9e226969f2dad6c6fd1728f4d9540809";
	rsig := NewArray(64, u8,, temp);
	for 0..63 rsig[it] = cast(u8) string_to_int(slice(release_sig, 2 * it, 2), 16);
	h, ok = su.manifest_hash(release_manifest, rsig, "v0.0.0");
	check(ok && crypto.constant_time_equal(h, crypto.sha256(xx "test")), "the pinned key accepts the release key's openssl signature");

	#if OS == .MACOS {
		check(su.target_of("/Applications/Fastcord.app/Contents/MacOS/Fastcord") == "/Applications/Fastcord.app", "the Mac target is the bundle");
		check(su.target_of("/Volumes/Fastcord/Fastcord.app/Contents/MacOS/Fastcord") == "", "a disk image isn't updated");
		check(su.target_of("/private/var/folders/x/AppTranslocation/y/d/Fastcord.app/Contents/MacOS/Fastcord") == "", "a translocated app isn't updated");
		check(su.target_of("/Users/me/build/fastcord-dev") == "", "a bare binary isn't a Mac target");
	}

	// install: a new copy packed like the release, swapped over an old one.
	dir := tprint("%/build/selfupdate_test", get_working_directory());
	su.delete_path(dir);
	make_directory_if_it_does_not_exist(tprint("%/pack", dir), recursive = true);
	#if OS == .MACOS {
		target := tprint("%/Fastcord.app", dir);
		marker :: "/Contents/MacOS/Fastcord";
		make_directory_if_it_does_not_exist(tprint("%/pack/Fastcord.app/Contents/MacOS", dir), recursive = true);
		make_directory_if_it_does_not_exist(tprint("%/Contents/MacOS", target), recursive = true);
		write_entire_file(tprint("%/pack/Fastcord.app%", dir, marker), "new");
		pack := string.["/usr/bin/ditto", "-c", "-k", "--keepParent", tprint("%/pack/Fastcord.app", dir), tprint("%/a", dir)];
	} else #if OS == .WINDOWS {
		target := tprint("%/Fastcord.exe", dir);
		marker :: "";
		write_entire_file(tprint("%/pack/Fastcord.exe", dir), "new");
		pack := string.["C:\\Windows\\System32\\tar.exe", "-a", "-c", "-f", tprint("%/a.zip", dir), "-C", tprint("%/pack", dir), "Fastcord.exe"];
	} else {
		target := tprint("%/fastcord", dir);
		marker :: "";
		make_directory_if_it_does_not_exist(tprint("%/pack/fastcord", dir));
		write_entire_file(tprint("%/pack/fastcord/fastcord", dir), "new");
		pack := string.["tar", "-czf", tprint("%/a", dir), "-C", tprint("%/pack", dir), "fastcord"];
	}
	write_entire_file(join(target, marker,, temp), "old");
	check(run_command(..pack).exit_code == 0, "pack the archive");
	archive := read_entire_file(ifx OS == .WINDOWS then tprint("%/a.zip", dir) else tprint("%/a", dir));

	check(!su.install(xx "not an archive", target), "a broken archive fails");
	got := read_entire_file(join(target, marker,, temp));
	check(got == "old", "a failed install leaves the old copy");
	check(!file_exists(tprint("%.update", target)), "a failed install cleans its staging");

	check(su.install(xx archive, target), "install");
	check(read_entire_file(join(target, marker,, temp)) == "new", "the new copy is in place");
	check(read_entire_file(join(su.old_path(target), marker,, temp)) == "old", "the old copy is kept as .old");
	check(!file_exists(tprint("%.update", target)), "install cleans its staging");
	su.delete_path(su.old_path(target));
	check(!file_exists(su.old_path(target)), "the .old copy is removed");
	su.delete_path(dir);

	if failed { print("selfupdate: % FAILED\n", failed); exit(1); }
	print("selfupdate: all passed\n");
}
