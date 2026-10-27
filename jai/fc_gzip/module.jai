#import "Basic";
z :: #import "fc_zlib";
bytes :: #import "fc_bytes";
load :: (input: []u8, buf: *bytes.Buffer) -> z.Error {
    f: z.Inflater;
    z.inflater_init(*f, .Gzip);
    defer z.inflater_destroy(*f);
    ended, ok := z.feed(*f, input, *buf.buf);
    return ifx ok && ended then .None else .Corrupt;
}
