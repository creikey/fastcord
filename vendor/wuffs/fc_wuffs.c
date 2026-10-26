// fastcord's one translation unit for Wuffs: compiles only the modules we use and wraps them in a
// call-and-return API where the caller owns every byte (decoder state, work buffer, pixels).
// Built by build.sh / build.bat into build/fc_wuffs.obj (.o elsewhere); bound in src/imagefmt.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__JPEG
#include "wuffs-v0.4.c"

enum {
    FC_OK = 0,
    FC_TRUNCATED = 1,
    FC_CORRUPT = 2,
    FC_UNSUPPORTED = 3,
    FC_BAD_ARGUMENT = 4,
};

static int fc__status(wuffs_base__status st) {
    if (!st.repr) return FC_OK;
    if (st.repr == wuffs_base__suspension__short_read) return FC_TRUNCATED;
    if (strstr(st.repr, "truncated")) return FC_TRUNCATED;
    if (strstr(st.repr, "unsupported")) return FC_UNSUPPORTED;
    return FC_CORRUPT;
}

// Bytes of decoder state the caller provides to the calls below (any alignment of 16 or more).
size_t fc_jpeg_state_size(void) {
    return sizeof__wuffs_jpeg__decoder();
}

static int fc__jpeg_config(void *state, size_t state_len, const uint8_t *src, size_t src_len,
                           wuffs_base__io_buffer *io, wuffs_base__image_config *ic) {
    wuffs_jpeg__decoder *dec = (wuffs_jpeg__decoder *)state;
    if (state_len < sizeof__wuffs_jpeg__decoder()) return FC_BAD_ARGUMENT;
    wuffs_base__status st = wuffs_jpeg__decoder__initialize(dec, state_len, WUFFS_VERSION, WUFFS_INITIALIZE__DEFAULT_OPTIONS);
    if (st.repr) return fc__status(st);
    *io = wuffs_base__ptr_u8__reader((uint8_t *)src, src_len, true);
    return fc__status(wuffs_jpeg__decoder__decode_image_config(dec, ic, io));
}

// Reads the header: image size and the work buffer length fc_jpeg_decode needs.
int fc_jpeg_info(void *state, size_t state_len, const uint8_t *src, size_t src_len,
                 uint32_t *width, uint32_t *height, uint64_t *work_len) {
    wuffs_base__io_buffer io;
    wuffs_base__image_config ic;
    int r = fc__jpeg_config(state, state_len, src, src_len, &io, &ic);
    if (r) return r;
    *width = wuffs_base__pixel_config__width(&ic.pixcfg);
    *height = wuffs_base__pixel_config__height(&ic.pixcfg);
    *work_len = wuffs_jpeg__decoder__workbuf_len((wuffs_jpeg__decoder *)state).max_incl;
    return FC_OK;
}

// Decodes into rgba (width*height*4 bytes, straight alpha, rows top to bottom).
int fc_jpeg_decode(void *state, size_t state_len, const uint8_t *src, size_t src_len,
                   uint8_t *rgba, size_t rgba_len, uint8_t *work, size_t work_len) {
    wuffs_base__io_buffer io;
    wuffs_base__image_config ic;
    int r = fc__jpeg_config(state, state_len, src, src_len, &io, &ic);
    if (r) return r;
    uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
    uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
    if ((uint64_t)w * h * 4 > rgba_len) return FC_BAD_ARGUMENT;
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
    wuffs_base__pixel_buffer pb;
    wuffs_base__status st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(rgba, rgba_len));
    if (st.repr) return FC_BAD_ARGUMENT;
    st = wuffs_jpeg__decoder__decode_frame((wuffs_jpeg__decoder *)state, &pb, &io, WUFFS_BASE__PIXEL_BLEND__SRC,
                                           wuffs_base__make_slice_u8(work, work_len), NULL);
    return fc__status(st);
}
