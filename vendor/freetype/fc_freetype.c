// fastcord's wrapper over FreeType (vendor/freetype; the library itself is built from fc_freetype.sources,
// Linux only). Bound in src/gfx/text_freetype_linux.jai.
//
// - Load_SBit_Png: FreeType's hook for PNG glyph bitmaps (CBDT colour emoji, Noto Color Emoji), normally
//   src/sfnt/pngshim.c over libpng. This one decodes with Wuffs (fc_wuffs.c), so the sfnt module is
//   built file by file without pngshim.c, and FT_CONFIG_OPTION_USE_PNG is on (fc_config/).
// - A few accessors, so the Jai side reads no FreeType struct layouts.
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include <freetype/internal/ftobjs.h>
#include <stdint.h>
#include <stdlib.h>
#include "src/sfnt/pngshim.h"

// fc_wuffs.c
typedef struct { uint32_t width, height; uint64_t work_len; } fc_image_info;
typedef struct { uint32_t x0, y0, x1, y1; uint64_t duration_ms; uint8_t disposal; } fc_frame_info;
size_t fc_image_state_size(int format);
int fc_image_open(void *state, size_t state_len, int format, const uint8_t *src, size_t src_len, fc_image_info *info);
int fc_image_next_frame(void *state, fc_frame_info *fi);
int fc_image_decode_frame(void *state, uint8_t *canvas, size_t canvas_len, size_t stride, uint8_t *work, size_t work_len, int replace);
#define FC_PNG 1

// As pngshim.c: the PNG goes into the slot's bitmap at (x_offset, y_offset) as premultiplied BGRA, the
// bitmap and metrics sized from the PNG first when populate_map_and_metrics.
FT_LOCAL_DEF( FT_Error )
Load_SBit_Png( FT_GlyphSlot slot, FT_Int x_offset, FT_Int y_offset, FT_Int pix_bits, TT_SBit_Metrics metrics,
               FT_Memory memory, FT_Byte *data, FT_UInt png_len, FT_Bool populate_map_and_metrics,
               FT_Bool metrics_only ) {
    FT_Bitmap *map = &slot->bitmap;
    (void)memory;
    if (x_offset < 0 || y_offset < 0) return FT_Err_Invalid_Argument;
    if (!populate_map_and_metrics && ((FT_UInt)x_offset + metrics->width > map->width ||
            (FT_UInt)y_offset + metrics->height > map->rows || pix_bits != 32 || map->pixel_mode != FT_PIXEL_MODE_BGRA))
        return FT_Err_Invalid_Argument;
    size_t n = fc_image_state_size(FC_PNG);
    void *state = malloc(n), *work = NULL;
    uint8_t *rgba = NULL;
    FT_Error error = FT_Err_Invalid_File_Format;
    fc_image_info info;
    fc_frame_info fi;
    if (!state) return FT_Err_Out_Of_Memory;
    if (fc_image_open(state, n, FC_PNG, data, png_len, &info)) goto Exit;
    if (info.width > 0x7FFF || info.height > 0x7FFF) { error = FT_Err_Array_Too_Large; goto Exit; }
    if (!populate_map_and_metrics && (info.width != metrics->width || info.height != metrics->height)) goto Exit;
    if (populate_map_and_metrics) {
        metrics->width = (FT_UShort)info.width;
        metrics->height = (FT_UShort)info.height;
        map->width = info.width;
        map->rows = info.height;
        map->pixel_mode = FT_PIXEL_MODE_BGRA;
        map->pitch = (int)(info.width * 4);
        map->num_grays = 256;
    }
    error = FT_Err_Ok;
    if (metrics_only) goto Exit;
    error = FT_Err_Out_Of_Memory;
    size_t len = (size_t)info.width * info.height * 4;
    work = malloc(info.work_len ? info.work_len : 1);
    rgba = calloc(len ? len : 1, 1);
    if (!work || !rgba) goto Exit;
    error = FT_Err_Invalid_File_Format;
    if (fc_image_next_frame(state, &fi) || fc_image_decode_frame(state, rgba, len, (size_t)info.width * 4, work, info.work_len, 1)) goto Exit;
    if (populate_map_and_metrics && (error = ft_glyphslot_alloc_bitmap(slot, (FT_ULong)map->rows * (FT_ULong)map->pitch))) goto Exit;
    for (uint32_t y = 0; y < info.height; y++) {
        const uint8_t *s = rgba + (size_t)y * info.width * 4;
        uint8_t *d = map->buffer + (size_t)(y_offset + y) * map->pitch + x_offset * 4;
        for (uint32_t x = 0; x < info.width; x++, s += 4, d += 4) {
            unsigned a = s[3];
            d[0] = (uint8_t)((s[2] * a + 127) / 255);
            d[1] = (uint8_t)((s[1] * a + 127) / 255);
            d[2] = (uint8_t)((s[0] * a + 127) / 255);
            d[3] = (uint8_t)a;
        }
    }
    error = FT_Err_Ok;
Exit:
    free(rgba);
    free(work);
    free(state);
    return error;
}

typedef struct {
    int width, rows, pitch, pixel_mode;
    int left, top; // pen to the bitmap's left edge, and up to its top row (pixels)
    const unsigned char *buffer;
} fc_ft_bitmap;

// The glyph the last FT_Load_Glyph put in the face's slot.
void fc_ft_glyph_bitmap(FT_Face face, fc_ft_bitmap *b) {
    FT_GlyphSlot s = face->glyph;
    b->width = (int)s->bitmap.width;
    b->rows = (int)s->bitmap.rows;
    b->pitch = s->bitmap.pitch;
    b->pixel_mode = s->bitmap.pixel_mode;
    b->left = s->bitmap_left;
    b->top = s->bitmap_top;
    b->buffer = s->bitmap.buffer;
}

// FT_FACE_FLAG_* bits.
int fc_ft_face_flags(FT_Face face) { return (int)face->face_flags; }
int fc_ft_style_flags(FT_Face face) { return (int)face->style_flags; }

// For a face without outlines (CBDT emoji): selects the smallest strike of at least px pixels, else the
// largest. Returns its size in pixels, 0 if none.
float fc_ft_select_strike(FT_Face face, float px) {
    int best = -1;
    for (int i = 0; i < face->num_fixed_sizes; i++) {
        float s = face->available_sizes[i].y_ppem / 64.0f, b = best < 0 ? 0 : face->available_sizes[best].y_ppem / 64.0f;
        if (best < 0 || (b < px ? s > b : s >= px && s < b)) best = i;
    }
    if (best < 0 || FT_Select_Size(face, best)) return 0;
    return face->available_sizes[best].y_ppem / 64.0f;
}

// Sets one axis (e.g. 'wght') of a variable face to value, clamped to the axis; no-op on other faces.
void fc_ft_set_axis(FT_Face face, FT_ULong tag, double value) {
    FT_MM_Var *mm;
    FT_Fixed c[16];
    if (!FT_HAS_MULTIPLE_MASTERS(face) || FT_Get_MM_Var(face, &mm)) return;
    FT_UInt n = mm->num_axis < 16 ? mm->num_axis : 16;
    if (!FT_Get_Var_Design_Coordinates(face, n, c)) {
        for (FT_UInt i = 0; i < n; i++) {
            if (mm->axis[i].tag != tag) continue;
            FT_Fixed v = (FT_Fixed)(value * 65536);
            c[i] = v < mm->axis[i].minimum ? mm->axis[i].minimum : v > mm->axis[i].maximum ? mm->axis[i].maximum : v;
        }
        FT_Set_Var_Design_Coordinates(face, n, c);
    }
    FT_Done_MM_Var(face->glyph->library, mm);
}
