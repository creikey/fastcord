// fastcord's one translation unit for Wuffs: compiles only the modules we use and wraps them in a
// call-and-return API where the caller owns every byte (decoder state, work buffer, pixels).
// Built by build.sh / build.bat into build/fc_wuffs.obj (.o elsewhere); bound in src/imagefmt.

// Scalar code on Windows: clang 11's MSVC-mode headers lack the AVX2 types Wuffs' SIMD paths use, and
// MSVC needs /arch:AVX2 for them.
#if defined(_WIN32)
#define WUFFS_CONFIG__AVOID_CPU_ARCH
#endif
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__VP8
#define WUFFS_CONFIG__MODULE__WEBP
#include "wuffs-v0.4.c"

enum {
    FC_OK = 0,
    FC_TRUNCATED = 1,
    FC_CORRUPT = 2,
    FC_UNSUPPORTED = 3,
    FC_BAD_ARGUMENT = 4,
    FC_END = 5,
};

// Same values as imagefmt.Format.
enum {
    FC_PNG = 1,
    FC_GIF = 2,
    FC_JPEG = 3,
    FC_WEBP = 4, // Still images only: Wuffs v0.4 can't animate WebP, so each frame comes as its own file.
};

typedef struct {
    uint32_t width, height;
    uint64_t work_len;
} fc_image_info;

typedef struct {
    uint32_t x0, y0, x1, y1;   // Frame rectangle, clipped to the image.
    uint64_t duration_ms;
    uint8_t disposal;          // After showing: 0 keep, 1 clear the rectangle, 2 restore the canvas from before.
} fc_frame_info;

// The caller's state blob: this header, then the format's decoder.
typedef struct {
    wuffs_base__image_decoder *dec;
    wuffs_base__io_buffer io;
    wuffs_base__image_config ic;
    wuffs_base__frame_config fc;
} fc__image;

#define FC__HEADER ((sizeof(fc__image) + 15) & ~(size_t)15)

static int fc__status(wuffs_base__status st) {
    if (!st.repr) return FC_OK;
    if (st.repr == wuffs_base__note__end_of_data) return FC_END;
    if (st.repr == wuffs_base__suspension__short_read) return FC_TRUNCATED;
    if (strstr(st.repr, "truncated")) return FC_TRUNCATED;
    if (strstr(st.repr, "unsupported")) return FC_UNSUPPORTED;
    return FC_CORRUPT;
}

static size_t fc__decoder_size(int format) {
    switch (format) {
    case FC_PNG: return sizeof__wuffs_png__decoder();
    case FC_GIF: return sizeof__wuffs_gif__decoder();
    case FC_JPEG: return sizeof__wuffs_jpeg__decoder();
    case FC_WEBP: return sizeof__wuffs_webp__decoder();
    }
    return 0;
}

// Bytes of state (any alignment of 16 or more) the caller provides for one image of this format; 0 if
// the format is unknown.
size_t fc_image_state_size(int format) {
    size_t n = fc__decoder_size(format);
    return n ? FC__HEADER + n : 0;
}

// Reads the header: image size and the work buffer length fc_image_decode_frame needs. src must stay
// alive and unchanged until the last call on this state.
int fc_image_open(void *state, size_t state_len, int format, const uint8_t *src, size_t src_len, fc_image_info *info) {
    size_t n = fc__decoder_size(format);
    if (!n || state_len < FC__HEADER + n) return FC_BAD_ARGUMENT;
    fc__image *im = (fc__image *)state;
    void *d = (uint8_t *)state + FC__HEADER;
    uint32_t opt = WUFFS_INITIALIZE__DEFAULT_OPTIONS;
    wuffs_base__status st;
    switch (format) {
    case FC_PNG:
        st = wuffs_png__decoder__initialize(d, n, WUFFS_VERSION, opt);
        im->dec = wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(d);
        break;
    case FC_GIF:
        st = wuffs_gif__decoder__initialize(d, n, WUFFS_VERSION, opt);
        im->dec = wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(d);
        break;
    case FC_JPEG:
        st = wuffs_jpeg__decoder__initialize(d, n, WUFFS_VERSION, opt);
        im->dec = wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(d);
        break;
    default:
        st = wuffs_webp__decoder__initialize(d, n, WUFFS_VERSION, opt);
        im->dec = wuffs_webp__decoder__upcast_as__wuffs_base__image_decoder(d);
        break;
    }
    if (st.repr) return fc__status(st);
    im->io = wuffs_base__ptr_u8__reader((uint8_t *)src, src_len, true);
    int r = fc__status(wuffs_base__image_decoder__decode_image_config(im->dec, &im->ic, &im->io));
    if (r) return r == FC_END ? FC_CORRUPT : r;
    uint32_t w = wuffs_base__pixel_config__width(&im->ic.pixcfg);
    uint32_t h = wuffs_base__pixel_config__height(&im->ic.pixcfg);
    wuffs_base__pixel_config__set(&im->ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
    info->width = w;
    info->height = h;
    info->work_len = wuffs_base__image_decoder__workbuf_len(im->dec).max_incl;
    return FC_OK;
}

// Times to play the animation, 0 = forever. Exact only once every frame has been read: GIF's loop
// count may come late, and a GIF without one plays once.
uint32_t fc_image_loops(void *state) {
    return wuffs_base__image_decoder__num_animation_loops(((fc__image *)state)->dec);
}

// Reads the next frame's header; FC_END when there are no more frames.
int fc_image_next_frame(void *state, fc_frame_info *fi) {
    fc__image *im = (fc__image *)state;
    int r = fc__status(wuffs_base__image_decoder__decode_frame_config(im->dec, &im->fc, &im->io));
    if (r) return r;
    wuffs_base__rect_ie_u32 fb = wuffs_base__frame_config__bounds(&im->fc);
    wuffs_base__rect_ie_u32 b = wuffs_base__rect_ie_u32__intersect(&fb, wuffs_base__pixel_config__bounds(&im->ic.pixcfg));
    fi->x0 = b.min_incl_x;
    fi->y0 = b.min_incl_y;
    fi->x1 = b.max_excl_x > b.min_incl_x ? b.max_excl_x : b.min_incl_x;
    fi->y1 = b.max_excl_y > b.min_incl_y ? b.max_excl_y : b.min_incl_y;
    fi->duration_ms = (uint64_t)wuffs_base__frame_config__duration(&im->fc) / WUFFS_BASE__FLICKS_PER_MILLISECOND;
    fi->disposal = wuffs_base__frame_config__disposal(&im->fc);
    return FC_OK;
}

// Draws the frame fc_image_next_frame just read onto the canvas: width*height RGBA pixels (straight
// alpha), rows `stride` bytes apart. Only the frame's rectangle changes, which `replace` overwrites even
// where the frame asks to be blended.
int fc_image_decode_frame(void *state, uint8_t *canvas, size_t canvas_len, size_t stride, uint8_t *work, size_t work_len, int replace) {
    fc__image *im = (fc__image *)state;
    uint32_t w = wuffs_base__pixel_config__width(&im->ic.pixcfg);
    uint32_t h = wuffs_base__pixel_config__height(&im->ic.pixcfg);
    if (stride < (size_t)w * 4 || (h && (uint64_t)(h - 1) * stride + (uint64_t)w * 4 > canvas_len)) return FC_BAD_ARGUMENT;
    wuffs_base__pixel_buffer pb;
    wuffs_base__table_u8 t = wuffs_base__make_table_u8(canvas, (size_t)w * 4, h, stride);
    if (wuffs_base__pixel_buffer__set_interleaved(&pb, &im->ic.pixcfg, t, wuffs_base__empty_slice_u8()).repr) return FC_BAD_ARGUMENT;
    wuffs_base__pixel_blend blend = replace || wuffs_base__frame_config__overwrite_instead_of_blend(&im->fc)
        ? WUFFS_BASE__PIXEL_BLEND__SRC : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
    int r = fc__status(wuffs_base__image_decoder__decode_frame(im->dec, &pb, &im->io, blend,
                                                              wuffs_base__make_slice_u8(work, work_len), NULL));
    return r == FC_END ? FC_CORRUPT : r;
}
