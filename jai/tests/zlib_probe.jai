#import "Basic";
#import "fc";
gzip :: #import "fc_gzip";
bytes :: #import "fc_bytes";
File :: #import "File";
main :: () {
    src := File.read_entire_file("build/big.json.gz");
    want := File.read_entire_file("build/big.json");
    buf: bytes.Buffer;
    err := gzip.load(to_bytes(src), *buf);
    print("gzip: % out % want % equal %\n", err, buf.buf.count, want.count, as_string(buf.buf) == want);
    print("temp occupied %\n", context.temporary_storage.total_bytes_occupied);
}
