// fastcord's wrapper over libjpeg-turbo's encoder (vendor/libjpeg-turbo, the library itself is built from
// fc_libjpeg_turbo.sources). Built by build.jai into build/fc_vendor.a; bound in src/imagefmt.
//
// fc_jpeg_encode encodes as Chromium's canvas.toDataURL("image/jpeg") does: blink's default quality 0.92
// (quality 92 here), and Skia's SkJpegEncoder (src/encode/SkJpegEncoderImpl.cpp): jpeg_set_defaults,
// jpeg_set_quality(q, TRUE), 4:2:0, the JFIF header, baseline Huffman tables.
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include "jpeglib.h"

typedef struct {
    struct jpeg_error_mgr mgr;
    jmp_buf jump;
} fc_jpeg_error;

// libjpeg's default error_exit calls exit(): jump back out instead.
static void fc_jpeg_fail(j_common_ptr c) { longjmp(((fc_jpeg_error*)c->err)->jump, 1); }
static void fc_jpeg_quiet(j_common_ptr c, int level) {}

// RGB8 (w * 3 bytes per row) to a baseline JPEG. Returns the size, 0 on failure; *out is freed with
// fc_jpeg_free.
size_t fc_jpeg_encode(const unsigned char* rgb, int w, int h, int quality, unsigned char** out) {
    struct jpeg_compress_struct c;
    fc_jpeg_error err;
    unsigned char* volatile mem = NULL;
    unsigned long size = 0;
    *out = NULL;
    c.err = jpeg_std_error(&err.mgr);
    err.mgr.error_exit = fc_jpeg_fail;
    err.mgr.emit_message = fc_jpeg_quiet;
    if (setjmp(err.jump)) {
        jpeg_destroy_compress(&c);
        free(mem);
        return 0;
    }
    jpeg_create_compress(&c);
    jpeg_mem_dest(&c, (unsigned char**)&mem, &size);
    c.image_width = (JDIMENSION)w;
    c.image_height = (JDIMENSION)h;
    c.input_components = 3;
    c.in_color_space = JCS_RGB;
    jpeg_set_defaults(&c);
    jpeg_set_quality(&c, quality, TRUE);
    jpeg_start_compress(&c, TRUE);
    while (c.next_scanline < c.image_height) {
        JSAMPROW row = (JSAMPROW)(rgb + (size_t)c.next_scanline * w * 3);
        jpeg_write_scanlines(&c, &row, 1);
    }
    jpeg_finish_compress(&c);
    jpeg_destroy_compress(&c);
    *out = mem;
    return size;
}

void fc_jpeg_free(void* p) { free(p); }
