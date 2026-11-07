/*
 * A STRETCHED COLUMN (Reference#exec_draw_column_at): one column of a picture painted at a height
 * the game works out as it runs, the way a game that draws a view down a corridor fills its screen.
 * A runtime feature (backends/runtime_features.rb): this file is included at the end of rg_screen.c,
 * for a game that draws a column, so it reads the screen's own state and painters as if it were
 * written there. A game that never does builds without it.
 *
 * The screen never asks it anything: the game calls rg_screen_column (declared in rg_columns.h).
 */
#include "rg_columns.h"

/* Reference#exec_draw_column_at: one column of a picture, stretched to +height+ rows. The walk
 * goes DOWN THE SCREEN and asks which row of the picture belongs at each screen row, the step
 * held in 65536ths of a picture row and cut off at each step — the console's own rule, so every
 * pixel lands where the other backends put it. Only the rows on the screen are walked. */
void rg_screen_column(int32_t image, int32_t slice, int32_t x, int32_t top, int32_t height, int32_t width) {
  if (height <= 0) return;
  picture art = picture_of(image);
  int64_t column = clamp32(slice, 0, art.width - 1);
  int64_t step = ((int64_t)art.height << 16) / height;
  int64_t first = top < 0 ? -(int64_t)top : 0;
  int64_t past = (int64_t)RG_SCREEN_HEIGHT - top < height ? (int64_t)RG_SCREEN_HEIGHT - top : height;
  for (int64_t row = first; row < past; row++) {
    int64_t source = clamp32((row * step) >> 16, 0, art.height - 1);
    int32_t color = art.pixels[source * art.width + column];
    if (color == RG_NOT_DRAWN) continue;
    for (int32_t across = 0; across < width; across++) set_pixel((int64_t)x + across, top + row, color);
  }
}
