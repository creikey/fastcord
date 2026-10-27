// fastcord's wrapper over libwebp's encoder and mux (vendor/libwebp, the library itself is built from
// fc_libwebp.sources). Built by build.sh / build.bat into build/fc_libwebp.obj (.o elsewhere); bound
// in src/imagefmt.
//
// fc_webp_lossless encodes as Chromium's canvas.toBlob("image/webp", 1) does: blink's
// ImageEncoder::ComputeWebpOptions picks lossless at quality 75 for quality 1.0, and Skia's
// SkWebpEncoder (src/encode/SkWebpEncoderImpl.cpp) sets lossless = 1, method = 0, use_argb = 1,
// imports unpremultiplied RGBA and, when the pixmap has a colour space, adds its ICC profile with
// WebPMux (VP8X + ICCP + VP8L).
#include "src/webp/encode.h"
#include "src/webp/mux.h"

// RGBA8 (straight alpha, w * 4 bytes per row) to WebP; icc may be NULL. Returns the size, 0 on
// failure; *out is freed with fc_webp_free.
size_t fc_webp_lossless(const uint8_t* rgba, int w, int h, const uint8_t* icc, size_t icc_len, uint8_t** out) {
    WebPConfig config;
    WebPPicture pic;
    WebPMemoryWriter wr;
    *out = NULL;
    if (!WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, 75.0f) || !WebPPictureInit(&pic)) return 0;
    config.lossless = 1;
    config.method = 0;
    pic.use_argb = 1;
    pic.width = w;
    pic.height = h;
    WebPMemoryWriterInit(&wr);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &wr;
    int ok = WebPPictureImportRGBA(&pic, rgba, w * 4) && WebPEncode(&config, &pic);
    WebPPictureFree(&pic);
    if (ok && icc_len == 0) {
        *out = wr.mem;
        return wr.size;
    }
    WebPData img = {wr.mem, wr.size}, profile = {icc, icc_len}, all = {NULL, 0};
    WebPMux* mux = ok ? WebPMuxNew() : NULL;
    ok = mux && WebPMuxSetImage(mux, &img, 0) == WEBP_MUX_OK && WebPMuxSetChunk(mux, "ICCP", &profile, 0) == WEBP_MUX_OK &&
         WebPMuxAssemble(mux, &all) == WEBP_MUX_OK;
    WebPMuxDelete(mux);
    WebPMemoryWriterClear(&wr);
    if (!ok) {
        WebPDataClear(&all);
        return 0;
    }
    *out = (uint8_t*)all.bytes;
    return all.size;
}

void fc_webp_free(void* p) { WebPFree(p); }
