/*
 * A STRETCHED COLUMN (Reference#exec_draw_column_at): one column of a picture painted at a height
 * the game works out as it runs. A runtime feature (backends/runtime_features.rb), joined into the
 * runtime's script after rg_screen.js for a game that draws a column, so it reads the screen's own
 * state and painters as if it were written there. rg_columns.c says how, rule for rule; this is that
 * file written again, function for function.
 *
 * The screen never asks it anything: the game calls rg_screen_column.
 */

/* Reference#exec_draw_column_at */
function rg_screen_column(image, slice, x, top, height, width) {
  if (height <= 0) return;
  const art = picture_of(image);
  const column = clamp_number(slice, 0, art.width - 1);
  const step = Math.trunc((art.height * 65536) / height);
  const first = top < 0 ? -top : 0;
  const past = RG_SCREEN_HEIGHT - top < height ? RG_SCREEN_HEIGHT - top : height;
  for (let row = first; row < past; row++) {
    const source = clamp_number(Math.floor((row * step) / 65536), 0, art.height - 1);
    const color = art.pixels[art.start + source * art.width + column];
    if (color === RG_NOT_DRAWN) continue;
    for (let across = 0; across < width; across++) set_pixel(x + across, top + row, color);
  }
}
