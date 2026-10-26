#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
typedef struct { uint8_t size_bits_by_length[32]; uint32_t offsets_by_length[32]; size_t data_size; const uint8_t* data; } BrotliDictionary;
typedef struct { uint16_t prefix_suffix_size; const uint8_t* prefix_suffix; const uint16_t* prefix_suffix_map; uint32_t num_transforms; const uint8_t* transforms; const uint8_t* params; int16_t cut[10]; } BrotliTransforms;
const BrotliDictionary* BrotliGetDictionary(void);
const BrotliTransforms* BrotliGetTransforms(void);
static void pstr(const BrotliTransforms* t, int id) {
  const uint8_t* p = t->prefix_suffix + t->prefix_suffix_map[id]; int n = p[0]; putchar('"');
  for (int i = 1; i <= n; i++) { if (p[i] == '"' || p[i] == '\\') printf("\\%c", p[i]); else if (p[i] < 32 || p[i] > 126) printf("\\x%02x", p[i]); else putchar(p[i]); }
  putchar('"');
}
// Dumps the RFC 7932 dictionary (argv[1]) and prints the transform table, from libbrotlicommon.
// cc dump_dictionary.c -I/opt/homebrew/opt/brotli/include -L/opt/homebrew/opt/brotli/lib -lbrotlicommon
int main(int argc, char** argv) {
  const BrotliDictionary* d = BrotliGetDictionary();
  fprintf(stderr, "size %zu\n", d->data_size);
  for (int i = 0; i < 32; i++) fprintf(stderr, "%d:%d/%u ", i, d->size_bits_by_length[i], d->offsets_by_length[i]);
  FILE* f = fopen(argv[1], "wb"); fwrite(d->data, 1, d->data_size, f); fclose(f);
  const BrotliTransforms* t = BrotliGetTransforms();
  fprintf(stderr, "\nntransforms %u\n", t->num_transforms);
  for (uint32_t i = 0; i < t->num_transforms; i++) {
    printf("\t{"); pstr(t, t->transforms[i*3]); printf(", %d, ", t->transforms[i*3+1]); pstr(t, t->transforms[i*3+2]); printf("}, // %u\n", i);
  }
}
