/*
 * SPRITES AND THEIR DRAW ORDER (Reference#exec_present_objects and the sprites it keeps): the
 * sprites on screen this frame, taken off and put back on a picture that stays, kept for a picture
 * that is built again, turned and resized, left out of a crowded line, shown over a painted
 * screen, and put into blocks while the picture is pixelated. Also the order a worked-out draw
 * order places them in, and the collision test that reads their pictures. A runtime feature
 * (backends/runtime_features.rb): this file is included at the end of rg_screen.c, for a game that
 * declares a sprite, so it reads the screen's own state and painters as if it were written there.
 * A game with no sprite builds without it.
 */
#include "rg_sprites.h"

/* The sprites on screen this frame: being set (drawing), and as the last rebuild draws them.
 * One that turns or resizes carries its angle and its size for this frame, and whether its size
 * ever changes. One that loses slices to a crowded line has them listed in left_out, +cut_count+
 * of them from +cut_from+ (mark_slices_left_out). */
typedef struct { int32_t sprite, image, x, y, level, turned, angle, size, resizes, cut_from, cut_count; } placed_object;
static placed_object drawing[RG_MAX_SPRITES], sprite_layer[RG_MAX_SPRITES];
static int32_t drawing_count, sprite_layer_count;

/* Where each sprite was last drawn straight onto the picture, by its number, so that patch can
 * be put back before it is drawn again (Reference @obj_prev). */
typedef struct { int32_t drawn, x, y; } drawn_place;
static drawn_place last_drawn[RG_MAX_SPRITES];

/* SPRITES OVER A PAINTED PICTURE (Reference#show_objects_over_picture): a layer of their own in
 * front of the picture, at the screen's own places, one color or RG_NOTHING_IN_FRONT for each,
 * painted as the screen's plain layer (paint_onto_plain_layer) and shown while +over_picture_up+
 * (rg_sprites_front_layer). */
static uint16_t over_picture[RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT];
static int32_t over_picture_up;

/* Reference#set_see_through_for, for a sprite: the same, and what is painted is a sprite's, so
 * it is mixed with the picture as it is with no sprite on it and stays off that picture. */
static void mix_as_sprite(int32_t sprite) {
  mix_as_layer(rg_game_sprite_see_through[sprite]);
  painting_sprite = 1;
}

static int64_t whole_root(int64_t value);

/* WHICH ROWS OF THE SCREEN THE BOX OF A TURNED SPRITE IS SHOWN ON (Reference::TurnedBox, which
 * says why). The display counts the rows of a sprite's box in 256 lines that come round, and the
 * screen is fewer than that, so a box taller than the lines below the screen — a picture 64
 * pixels tall, whose box is 128 rows — shows its end at the top of the screen when it stands near
 * the bottom, and its start at the bottom when it hangs off the top. */
enum { TURNED_BOX_LINES = 256 };

/* The screen row the box row +row+ lands on when the box's first row is at +top+, or -1 for a
 * line below the screen, where the box stands unseen. */
static int64_t turned_box_line(int64_t top, int64_t row) {
  int64_t line = floor_mod(top + row, TURNED_BOX_LINES);
  return line < RG_SCREEN_HEIGHT ? line : -1;
}

/* TurnedBox.rows_shown's first test, with Affine.rows_reached: a sprite is drawn at all only
 * while some of the rows its picture can reach are on the screen, wherever the rest of its box
 * would come round to. A picture that +resizes+ can fill its whole box; one that only turns
 * stays within a square as wide as its diagonal, and a pixel each side, about the middle. */
static int turned_box_on_screen(int64_t top, int64_t width, int64_t height, int32_t resizes) {
  int64_t first = 0, past = height * 2;
  if (!resizes) {
    int64_t reach = whole_root(width * width + height * height) + 2;
    first = height - reach / 2;
    past = first + reach;
  }
  return top + past > 0 && top + first < RG_SCREEN_HEIGHT;
}

/* Reference#blit_image_transformed: a picture turned +angle+ degrees clockwise and drawn at
 * +size+, about its own middle, its top left as drawn at (x, y).
 *
 * The console does not turn the picture and stamp it down. It walks the patch of screen the
 * sprite can cover and, for each pixel of it, works BACK through the turn to the pixel of the
 * picture that lands there; one that falls outside the picture is not drawn. The patch is twice
 * the picture each way, centered on it, so a corner swung out by the turn has room, and a
 * picture grown past twice its size is cut off at that box. A screen pixel is taken at its whole
 * coordinate and the answer rounded down, which is what puts every edge pixel where the other
 * backends put it. Each row of the patch lands on the screen row the display counts it at (see
 * turned_box_line). */
static void blit_image_turned(int32_t image, int32_t x, int32_t y, int32_t angle, int32_t size, int32_t resizes) {
  picture art = picture_of(image);
  int64_t width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix((int32_t)floor_mod(angle, 360), size, &turn_cos, &turn_sin);
  int64_t left = (int64_t)x - width / 2, top = (int64_t)y - height / 2;
  if (!turned_box_on_screen(top, width, height, resizes)) return;
  for (int64_t iy = 0; iy < height * 2; iy++) {
    int64_t line = turned_box_line(top, iy);
    if (line < 0) continue;
    int64_t dy = iy - height;
    for (int64_t ix = 0; ix < width * 2; ix++) {
      int64_t dx = ix - width;
      int64_t from_x = floor_div(turn_cos * dx + turn_sin * dy, one_th) + width / 2;
      int64_t from_y = floor_div(-turn_sin * dx + turn_cos * dy, one_th) + height / 2;
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      int32_t color = art.pixels[from_y * width + from_x];
      if (color != RG_NOT_DRAWN) set_pixel(left + ix, line, color);
    }
  }
}

/* --- how many sprites a line of the screen shows (Backends::SpriteLines, which says how each
 * console picks) ---
 *
 * A console that draws only so many pieces of sprites on a line (RG_SPRITE_PIECES_A_LINE, 0 for
 * none) draws the first that many its table holds there and leaves the rest out of that line; of
 * those, one fetches only so many slivers eight pixels wide, from the back (RG_SPRITE_SLIVERS_A_LINE),
 * and one draws only so many pixels, from the front (RG_SPRITE_PIXELS_A_LINE). Each picture's pieces
 * are listed in rg_game_image_pieces: its first number is how many images are listed, its second the
 * game's entry reach (piece_takes_entry), then for each image where its list starts, and a list is how many pieces, then each piece's across, down, width
 * and height inside the picture, in the table's order. A slice left out is a piece on a line, from
 * one of its columns to its right edge. */
enum { MAX_LEFT_OUT = 16384, SLIVER = 8, PIECE_NUMBERS = 4, MAX_LINE_KEPT = 64 };
typedef struct { int32_t line, piece, from; } left_out_piece;
static left_out_piece left_out[MAX_LEFT_OUT];
static int32_t left_out_count;

static const int32_t *pieces_of_image(int32_t image) { return rg_screen_image_pieces(image); }

/* One piece kept on a line, as the line's limit works it out (SpriteLines.limit_line): its sprite's
 * place in the table's order, the piece, its left edge on the screen, its width, and the first of its
 * columns left out (its width for none). */
typedef struct { int32_t at, piece; int64_t left; int32_t width, from; } line_piece;

/* The slices found left out this frame, each with its sprite's place in the table's order, before
 * they are put in left_out sprite by sprite. */
static left_out_piece found_cut[MAX_LEFT_OUT];
static int32_t found_at[MAX_LEFT_OUT], found_count;

static void note_left_out(int32_t at, int64_t line, int32_t piece, int32_t from) {
  if (found_count >= MAX_LEFT_OUT) rg_fault("more than %d slices of sprites left out of crowded lines", MAX_LEFT_OUT);
  found_at[found_count] = at;
  found_cut[found_count++] = (left_out_piece){(int32_t)line, piece, from};
}

/* Whether a piece of +width+ by +height+ at +left+, +top+ is on the screen at all. */
static int piece_on_screen(int64_t left, int64_t top, int32_t width, int32_t height) {
  return left > -width && left < RG_SCREEN_WIDTH && top > -height && top < RG_SCREEN_HEIGHT;
}

/* Whether such a piece takes an entry of the table: one on the screen, or one as far past its left
 * or top edge as the game's entry reach (SpriteLines.entry_reach). */
static int piece_takes_entry(int64_t left, int64_t top, int32_t width, int32_t height) {
  int32_t reach = rg_game_image_pieces[1];
  return piece_on_screen(left, top, width > reach ? width : reach, height > reach ? height : reach);
}

/* SpriteLines.limit_slivers: slivers fetched from the piece furthest back, each piece's left to right,
 * those on the screen counted until RG_SPRITE_SLIVERS_A_LINE. */
static void limit_slivers(line_piece *kept, int32_t count) {
  int32_t fetched = 0;
  for (int32_t i = count - 1; i >= 0; i--)
    for (int32_t offset = 0; offset < kept[i].width; offset += SLIVER) {
      int64_t sliver = kept[i].left + offset;
      if (sliver <= -SLIVER || sliver >= RG_SCREEN_WIDTH) continue;
      if (fetched == RG_SPRITE_SLIVERS_A_LINE) {
        kept[i].from = offset;
        break;
      }
      fetched++;
    }
}

/* SpriteLines.limit_pixels: pieces drawn front-most first, each spending its whole width, until
 * RG_SPRITE_PIXELS_A_LINE; the one that crosses it keeps the pixels left. */
static void limit_pixels(line_piece *kept, int32_t count) {
  int64_t spent = 0;
  for (int32_t i = 0; i < count; i++) {
    if (spent + kept[i].width > RG_SPRITE_PIXELS_A_LINE) {
      int64_t left = RG_SPRITE_PIXELS_A_LINE - spent;
      kept[i].from = left < 0 ? 0 : (int32_t)left;
    }
    spent += kept[i].width;
  }
}

/* Reference#mark_slices_left_out: the slices of these sprites that a crowded line leaves out, and
 * the pieces a full table leaves out of every line (RG_SPRITE_PIECES_A_SCREEN, 0 for no limit). The
 * table lists them front-most first: the deepest level last, and inside a level the one drawn last
 * first, and is filled from the end RG_SPRITE_TABLE_FROM_BACK names. A piece takes an entry
 * (piece_takes_entry), and its place on every line of the screen it covers. Worked out a line at a
 * time, as the console does, then put in left_out sprite by sprite. */
static void mark_slices_left_out(placed_object *placed, int32_t count) {
  left_out_count = found_count = 0;
  for (int32_t i = 0; i < count; i++) placed[i].cut_from = placed[i].cut_count = 0;
  if ((RG_SPRITE_PIECES_A_LINE == 0 && RG_SPRITE_PIECES_A_SCREEN == 0) || count == 0) return;
  _Static_assert(RG_SPRITE_PIECES_A_LINE <= MAX_LINE_KEPT, "more pieces kept on a line than there is room for");
  int32_t order[RG_MAX_SPRITES];
  for (int32_t i = 0; i < count; i++) {
    int32_t at = i;
    while (at > 0 && placed[order[at - 1]].level <= placed[i].level) {
      order[at] = order[at - 1];
      at--;
    }
    order[at] = i;
  }
  /* Each sprite's first entry of the table, and the lines its pieces on the screen cover. */
  int32_t first_entry[RG_MAX_SPRITES], entries = 0;
  int64_t first_line[RG_MAX_SPRITES], past_line[RG_MAX_SPRITES];
  for (int32_t k = 0; k < count; k++) {
    const placed_object *sprite = &placed[order[k]];
    const int32_t *pieces = pieces_of_image(sprite->image);
    first_entry[k] = entries;
    first_line[k] = RG_SCREEN_HEIGHT;
    past_line[k] = 0;
    for (int32_t piece = 0; piece < pieces[0]; piece++) {
      const int32_t *p = pieces + 1 + PIECE_NUMBERS * piece;
      int64_t left = (int64_t)sprite->x + p[0], top = (int64_t)sprite->y + p[1];
      if (!piece_takes_entry(left, top, p[2], p[3])) continue;
      entries++;
      if (!piece_on_screen(left, top, p[2], p[3])) continue;
      if (top < first_line[k]) first_line[k] = top;
      if (top + p[3] > past_line[k]) past_line[k] = top + p[3];
    }
  }
  line_piece kept[MAX_LINE_KEPT];
  for (int64_t line = 0; line < RG_SCREEN_HEIGHT; line++) {
    int32_t kept_count = 0, on_line = 0;
    for (int32_t k = 0; k < count; k++) {
      if (line < first_line[k] || line >= past_line[k]) continue;
      const placed_object *sprite = &placed[order[k]];
      const int32_t *pieces = pieces_of_image(sprite->image);
      int32_t entry = first_entry[k];
      for (int32_t piece = 0; piece < pieces[0]; piece++) {
        const int32_t *p = pieces + 1 + PIECE_NUMBERS * piece;
        int64_t left = (int64_t)sprite->x + p[0], top = (int64_t)sprite->y + p[1];
        if (!piece_takes_entry(left, top, p[2], p[3])) continue;
        int in_table = RG_SPRITE_PIECES_A_SCREEN == 0 ||
                       (RG_SPRITE_TABLE_FROM_BACK ? entry >= entries - RG_SPRITE_PIECES_A_SCREEN : entry < RG_SPRITE_PIECES_A_SCREEN);
        entry++;
        if (!piece_on_screen(left, top, p[2], p[3]) || line < top || line >= top + p[3]) continue;
        if (!in_table) note_left_out(k, line, piece, 0);
        else if (RG_SPRITE_PIECES_A_LINE == 0) continue;
        else if (on_line++ >= RG_SPRITE_PIECES_A_LINE) note_left_out(k, line, piece, 0);
        else kept[kept_count++] = (line_piece){k, piece, left, p[2], p[2]};
      }
    }
    if (RG_SPRITE_SLIVERS_A_LINE != 0) limit_slivers(kept, kept_count);
    if (RG_SPRITE_PIXELS_A_LINE != 0) limit_pixels(kept, kept_count);
    for (int32_t i = 0; i < kept_count; i++)
      if (kept[i].from < kept[i].width) note_left_out(kept[i].at, line, kept[i].piece, kept[i].from);
  }
  /* Sprite by sprite: each sprite's slices together, in the order they were found. */
  for (int32_t k = 0; k < count; k++) {
    placed_object *sprite = &placed[order[k]];
    sprite->cut_from = left_out_count;
    for (int32_t i = 0; i < found_count; i++)
      if (found_at[i] == k) left_out[left_out_count++] = found_cut[i];
    sprite->cut_count = left_out_count - sprite->cut_from;
  }
}

/* SpriteLines.left_out_at?: is column +col+, row +row+ of a sprite's picture, on screen line +line+,
 * left out? It is where a piece covering it is left out there from that column, and no piece drawn
 * there covers it. */
static int left_out_at(const placed_object *placed, int64_t col, int64_t row, int64_t line) {
  const int32_t *pieces = pieces_of_image(placed->image);
  int32_t covered = 0;
  for (int32_t piece = 0; piece < pieces[0]; piece++) {
    const int32_t *p = pieces + 1 + PIECE_NUMBERS * piece;
    int64_t across = p[0], down = p[1];
    if (col < across || col >= across + p[2] || row < down || row >= down + p[3]) continue;
    int cut = 0;
    for (int32_t i = placed->cut_from; i < placed->cut_from + placed->cut_count && !cut; i++)
      cut = left_out[i].line == line && left_out[i].piece == piece && col - across >= left_out[i].from;
    if (!cut) return 0;
    covered = 1;
  }
  return covered;
}

/* Reference#blit_image with a sprite's slices left out. */
static void blit_with_slices_left_out(const placed_object *placed) {
  picture art = picture_of(placed->image);
  for (int32_t row = 0; row < art.height; row++)
    for (int32_t col = 0; col < art.width; col++) {
      int32_t color = art.pixels[row * art.width + col];
      int64_t line = (int64_t)placed->y + row;
      if (color != RG_NOT_DRAWN && !left_out_at(placed, col, row, line)) set_pixel((int64_t)placed->x + col, line, color);
    }
}

/* Reference#draw_object and #paint_snapshot_object */
static void draw_placed(const placed_object *placed) {
  if (placed->turned)
    blit_image_turned(placed->image, placed->x, placed->y, placed->angle, placed->size, placed->resizes);
  else if (placed->cut_count) blit_with_slices_left_out(placed);
  else blit_image(placed->image, placed->x, placed->y);
}

/* Reference#scene_framebuffer: the backdrop, and every background showing stamped over it
 * (rg_hook_stamp_scenery). It is a picture of its own, so an area the game's drawing is held to
 * does not hold this. */
static void keep_scenery(void) {
  if (scenery_kept) return;
  drawing_area outer = area;
  area.in_force = 0;
  target = scenery;
  clear_to(backdrop);
  rg_hook_stamp_scenery();
  target = pixels;
  area = outer;
  scenery_kept = 1;
}

/* The start of Reference#exec_present_objects. A game that draws its sprites straight onto the
 * picture has the scenery under them kept from here, as the interpreter does. */
void rg_objects_begin(void) {
  drawing_count = 0;
  if (!rebuilt_whole()) keep_scenery();
}

static void fault_unless_sprite(int32_t sprite) {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault("sprite number %d is not one of the %d there is room for", sprite, RG_MAX_SPRITES);
}

/* Framebuffer#put_back_cell: the scenery's cell at (x, y) put back on the picture, a mix kept as
 * one so that a tint still reaches both its sides. */
static void put_back_cell(int64_t x, int64_t y) {
  int64_t at = y * RG_SCREEN_WIDTH + x;
  set_pixel(x, y, scenery[at]);
  mixed_sides *kept = mixes_of(target);
  if (!kept || !paintable(x, y) || !scenery_mixes.is_mixed[at]) return;
  kept->is_mixed[at] = 1;
  kept->tops[at] = scenery_mixes.tops[at];
  kept->unders[at] = scenery_mixes.unders[at];
}

/* Reference#restore_patch: the scenery put back over a patch of the picture. */
static void restore_patch(int64_t left, int64_t top, int64_t width, int64_t height) {
  for (int64_t row = 0; row < height; row++)
    for (int64_t col = 0; col < width; col++) {
      int64_t x = left + col, y = top + row;
      if (on_screen(x, y)) put_back_cell(x, y);
    }
}

/* The same over a turned sprite's patch, each row on the screen row the display counts it at. */
static void restore_turned_patch(int64_t left, int64_t top, int64_t width, int64_t height) {
  for (int64_t row = 0; row < height; row++) {
    int64_t line = turned_box_line(top, row);
    if (line >= 0) restore_patch(left, line, width, 1);
  }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over for
 * the scenery to be put back there; NULL when it is not on the picture. */
static const drawn_place *forget_drawn_place(int32_t sprite) {
  fault_unless_sprite(sprite);
  drawn_place *place = &last_drawn[sprite];
  if (!place->drawn) return NULL;
  place->drawn = 0;
  return place;
}

/* Reference#restore_scene_rect: the scenery put back where this sprite was last drawn, over the
 * box every one of its pictures fits in, +width+ by +height+ (SpriteCut.canvas_of). */
void rg_object_take_off(int32_t sprite, int32_t width, int32_t height) {
  const drawn_place *place = forget_drawn_place(sprite);
  if (!place) return;
  restore_patch(place->x, place->y, width, height);
}

/* The whole number whose square is the largest not over +value+ (Ruby's Integer.sqrt). */
static int64_t whole_root(int64_t value) {
  int64_t root = 0;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

/* Reference#restore_scene_rect and #transformed_footprint, for a sprite that turns or resizes.
 * The patch has to hold the picture at whatever angle and size it was last drawn, since the
 * putting back cannot depend on knowing which. One that only turns reaches no further from its
 * middle than half its own diagonal, so a square that wide does; one that +resizes+ has no bound
 * short of the whole box the display gives it, twice the picture each way. Each row is put back
 * on the screen row it was drawn on, which for a tall box near an edge is the other edge (see
 * turned_box_line). */
void rg_object_take_off_turned(int32_t sprite, int32_t image, int32_t resizes) {
  const drawn_place *place = forget_drawn_place(sprite);
  if (!place) return;
  picture art = picture_of(image);
  int64_t width = art.width, height = art.height;
  int64_t middle_x = (int64_t)place->x + width / 2, middle_y = (int64_t)place->y + height / 2;
  if (resizes) {
    restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  int64_t side = whole_root(width * width + height * height) + 2;
  restore_turned_patch(middle_x - side / 2, middle_y - side / 2, side, side);
}

/* One more sprite on screen this frame. */
static void add_placed(placed_object placed) {
  fault_unless_sprite(placed.sprite);
  if (drawing_count >= RG_MAX_SPRITES) rg_fault("more than %d sprites on screen at once", RG_MAX_SPRITES);
  drawing[drawing_count++] = placed;
}

void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level) {
  add_placed((placed_object){.sprite = sprite, .image = image, .x = x, .y = y, .level = level});
}

void rg_objects_add_turned(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level, int32_t angle,
                           int32_t size, int32_t resizes) {
  add_placed((placed_object){.sprite = sprite, .image = image, .x = x, .y = y, .level = level,
                             .turned = 1, .angle = angle, .size = size, .resizes = resizes});
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
 * screen now are kept (#snapshot_object_layer) and the rebuild is owed, unless they are the
 * sprites, in the same places, that the last rebuild painted: the interpreter builds it every
 * time, and this only when something moved. On one that is not, each is drawn where it is now,
 * and where that was is remembered for taking it off again. */
void rg_objects_end(void) {
  mark_slices_left_out(drawing, drawing_count);
  /* Kept whichever way the picture is made: a scene taking over later in this pass builds the
   * picture again from it (rg_scene_redraw_sprites). Compared as they are laid down, field by
   * field, so nothing is worked out for a frame where nothing moved. */
  int32_t moved = rebuilt_whole() && (drawing_count != sprite_layer_count ||
                  memcmp(sprite_layer, drawing, (size_t)drawing_count * sizeof drawing[0]) != 0);
  for (int32_t i = 0; i < drawing_count; i++) sprite_layer[i] = drawing[i];
  sprite_layer_count = drawing_count;
  /* Reference#show_objects_over_picture: on a painted screen of a game whose sprites are shown over
   * the picture, they go in the layer in front of it, and never into it. */
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SPRITES_OVER_PICTURE]) {
    for (int32_t at = 0; at < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; at++) over_picture[at] = RG_NOTHING_IN_FRONT;
    paint_onto_plain_layer(over_picture);
    for (int32_t i = 0; i < drawing_count; i++) draw_placed(&drawing[i]);
    paint_onto_plain_layer(NULL);
    over_picture_up = drawing_count > 0;
    return;
  }
  if (rebuilt_whole()) {
    if (moved) request_repaint();
    else skip_repaint();
    return;
  }
  /* The sprite layer is off while a painted screen is up in a game with screens drawn from tiles. */
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  for (int32_t i = 0; i < drawing_count; i++) {
    mix_as_sprite(drawing[i].sprite);
    draw_placed(&drawing[i]);
    mix_nothing();
    last_drawn[drawing[i].sprite] = (drawn_place){1, drawing[i].x, drawing[i].y};
  }
}

/* Which of a row of +count+ things the number +said+ names, read the way the interpreter reads
 * a Ruby array: a number below nought counts back from the last. NO_PLACE when it still names
 * none, which is where the interpreter stops with an error. */
enum { NO_PLACE = -1 };
static int64_t place_named(int32_t said, int32_t count) {
  int64_t place = said < 0 ? (int64_t)said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order: the sprite of a run that the order list names next. */
int32_t rg_place_in_ordered_run(int32_t said, int32_t count) {
  int64_t place = place_named(said, count);
  if (place == NO_PLACE) rg_fault("a draw order names sprite %d of the %d it puts in order", said, count);
  return (int32_t)place;
}

/* Reference#collision_sprite: the picture a sprite is showing. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose) {
  int64_t place = place_named(pose, count);
  if (place == NO_PLACE) rg_fault("a sprite is showing picture %d of its %d", pose, count);
  return poses[place];
}

/* Reference#solid_pixel? */
static int32_t solid_pixel(picture art, int64_t col, int64_t row) {
  return art.pixels[row * art.width + col] != RG_NOT_DRAWN;
}

/* Reference#pixels_overlap?: only the rectangle where the two boxes overlap is walked. */
int32_t rg_pixels_overlap(int32_t a_image, int32_t a_x, int32_t a_y, int32_t b_image, int32_t b_x, int32_t b_y) {
  picture a = picture_of(a_image), b = picture_of(b_image);
  int64_t left = a_x > b_x ? a_x : b_x, top = a_y > b_y ? a_y : b_y;
  int64_t a_right = (int64_t)a_x + a.width, b_right = (int64_t)b_x + b.width;
  int64_t a_bottom = (int64_t)a_y + a.height, b_bottom = (int64_t)b_y + b.height;
  int64_t right = a_right < b_right ? a_right : b_right, bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (int64_t y = top; y < bottom; y++)
    for (int64_t x = left; x < right; x++)
      if (solid_pixel(a, x - a_x, y - a_y) && solid_pixel(b, x - b_x, y - b_y)) return 1;
  return 0;
}

/* --- a sprite in blocks (Reference::SpriteBlocks, which holds the rule and says why) ---
 *
 * The blocks are fixed to the screen, as a background's are. What differs is where a block takes
 * its color from, because a sprite is a small box and a block need not start inside it. */

static int64_t clamp64(int64_t value, int64_t low, int64_t high) { return value < low ? low : (value > high ? high : value); }

/* SpriteBlocks#block_start and #round_up: where the block a column or row is in starts, and the
 * end of the block an edge falls in, for blocks of +sprite_block+: the size the sprite being painted
 * is put into, asked once a sprite (paint_kept_sprite), never once a pixel. */
static int32_t sprite_block = 1;
static int64_t block_start(int64_t at) { return at - floor_mod(at, sprite_block); }
static int64_t block_end(int64_t edge) { return -floor_div(-edge, sprite_block) * sprite_block; }

/* Reference#picture_reader: what a picture shows at a column and row of itself, or RG_NOT_DRAWN
 * where it is see-through and anywhere outside it. */
static int32_t picture_color(picture art, int64_t col, int64_t row) {
  if (col < 0 || col >= art.width || row < 0 || row >= art.height) return RG_NOT_DRAWN;
  return art.pixels[row * art.width + col];
}

/* SpriteBlocks#paint_box: one box of a sprite whose picture's corner is at (x, y), the box's own
 * corner at (left, top) on the screen. A block that starts left of the box or above it shows the
 * box's first column or row; the last block across is drawn whole, past the box's right edge;
 * nothing is drawn past its bottom edge. */
static void paint_box_in_blocks(picture art, int64_t x, int64_t y, int64_t left, int64_t top, int64_t width, int64_t height) {
  int64_t first_row = top > 0 ? top : 0, past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT;
  int64_t first_col = left > 0 ? left : 0, past_col = block_end(left + width);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  for (int64_t py = first_row; py < past_row; py++) {
    int64_t from_y = clamp64(block_start(py), top, top + height - 1);
    for (int64_t px = first_col; px < past_col; px++) {
      int32_t color = picture_color(art, clamp64(block_start(px), left, left + width - 1) - x, from_y - y);
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* SpriteBlocks#paint_upright: a sprite that stands upright, a box at a time, back to front, so
 * where one box's last block runs over the next the one in front wins. The boxes are the ones
 * listed for the picture it shows (rg_game_sprite_boxes). */
static void paint_upright_in_blocks(const placed_object *placed) {
  const int32_t *listed = rg_game_sprite_boxes + rg_game_sprite_blocks[placed->sprite];
  int32_t pictures = *listed++, showing = rg_game_image_pictures[placed->image];
  for (int32_t i = 0; i < pictures; i++) {
    int32_t name = listed[0], boxes = listed[1];
    const int32_t *box = listed + 2;
    listed = box + 4 * boxes;
    if (name != showing) continue;
    picture art = picture_of(placed->image);
    for (int32_t b = boxes - 1; b >= 0; b--)
      paint_box_in_blocks(art, placed->x, placed->y, (int64_t)placed->x + box[4 * b], (int64_t)placed->y + box[4 * b + 1],
                          box[4 * b + 2], box[4 * b + 3]);
    return;
  }
  rg_fault("sprite %d is shown in blocks and has no boxes for the picture it shows", placed->sprite);
}

/* SpriteBlocks#turned_row: the row of its box a turned sprite shows on screen row +py+, which is
 * the row at the top of the block, held to the box's first row when the block began above it. It
 * is worked out as the display counts, in lines that come round, which is where the odd case
 * comes from: a box that ends past the last line the display counts reads its last row on every
 * row that shows. */
static int64_t turned_row(int64_t py, int64_t top, int64_t height) {
  enum { LINES = 256 };
  int64_t first = floor_mod(top, LINES), past = first + height, line = block_start(py);
  if (line < first && first < RG_SCREEN_HEIGHT) line = first;
  if (line >= past % LINES) line = past - 1;
  return floor_mod(line - first, LINES);
}

/* SpriteBlocks#paint_turned, and the walk back to the picture Reference#paint_object_in_blocks
 * hands it: a sprite that turns or resizes, drawn in a box twice its picture's size about the
 * picture's middle. A block that starts left of the box shows what the turned picture would show
 * ONE COLUMN before the box begins, which is nearly always nothing; one that starts above it
 * shows the box's first row; and the last block across is drawn whole. */
static void paint_turned_in_blocks(const placed_object *placed) {
  picture art = picture_of(placed->image);
  int64_t width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix((int32_t)floor_mod(placed->angle, 360), placed->size, &turn_cos, &turn_sin);
  int64_t left = (int64_t)placed->x - width / 2, top = (int64_t)placed->y - height / 2;
  int64_t first_col = left > 0 ? left : 0, past_col = block_end(left + width * 2);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  if (!turned_box_on_screen(top, width, height, placed->resizes)) return;
  for (int64_t iy = 0; iy < height * 2; iy++) {
    int64_t py = turned_box_line(top, iy);
    if (py < 0) continue;
    int64_t dy = turned_row(py, top, height * 2) - height;
    for (int64_t px = first_col; px < past_col; px++) {
      int64_t start = block_start(px);
      int64_t dx = (start >= left ? start : left - 1) - left - width;
      int32_t color = picture_color(art, floor_div(turn_cos * dx + turn_sin * dy, one_th) + width / 2,
                                    floor_div(-turn_sin * dx + turn_cos * dy, one_th) + height / 2);
      if (color != RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}


/* Reference#paint_snapshot_object: one of the sprites kept for a rebuild is drawn in blocks while
 * the picture is shown in them (rg_hook_block_size), unless the game leaves it as drawn. */
static void paint_kept_sprite(const placed_object *placed) {
  sprite_block = rg_hook_block_size();
  if (sprite_block == 1 || rg_game_sprite_blocks[placed->sprite] == RG_NOT_IN_BLOCKS) draw_placed(placed);
  else if (placed->turned) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
}

/* --- the hooks it takes --- */

/* Reference#repaint_view, for sprites: the sprites kept for the rebuild that sit at this level, drawn
 * after the level's scenery (this feature comes after the tiled one), each mixed and faded as its
 * layer is. */
static void rg_sprites_paint_level(int32_t level) {
  for (int32_t i = 0; i < sprite_layer_count; i++) {
    if (sprite_layer[i].level != level) continue;
    mix_as_sprite(sprite_layer[i].sprite);
    fade_unless_left_as_drawn(rg_game_sprite_fade_places[sprite_layer[i].sprite]);
    paint_kept_sprite(&sprite_layer[i]);
  }
}

/* Reference#exec_screen: what was under each sprite went with the old screen, so nothing is put back
 * over the new one. A console that places its sprites at the end of a pass takes them off after this. */
static void rg_sprites_screen_crossed(int32_t new_kind) {
  (void)new_kind;
  memset(last_drawn, 0, sizeof last_drawn);
  over_picture_up = 0;
}

/* Reference#sprites: what the game last put on screen, which stays as it was put from
 * rg_objects_end until the next rg_objects_begin. */
static int32_t rg_sprites_drawn_count(void) { return drawing_count; }

static rg_drawn_sprite rg_sprites_drawn_sprite(int32_t place) {
  const placed_object *placed = &drawing[place];
  return (rg_drawn_sprite){rg_game_sprite_names[placed->sprite], rg_game_image_pictures[placed->image], placed->x,
                           placed->y};
}

/* Reference#redraw_sprites_over_arrived_scenery asks whether any sprite was kept when it was drawn. */
static int32_t rg_sprites_any_sprite_kept(void) { return sprite_layer_count > 0; }

/* Framebuffer#shown and #pixel, with sprites over a painted screen: the layer in front, while any
 * sprite is in it. */
static const uint16_t *rg_sprites_front_layer(void) { return over_picture_up ? over_picture : NULL; }

/* --- the state image --- */

/* Each sprite on screen in "sprites.drawing" and "sprites.kept": its number, picture, place and
 * level, its turn (turned, angle, size, whether it resizes), and how many slices a crowded line
 * leaves out of it, which follow in the field after, a line, a piece and its first column left out
 * each. */
enum {
  PLACED_STATE_NUMBERS = 10, PLACED_SPRITE = 0, PLACED_IMAGE = 1, PLACED_X = 2, PLACED_Y = 3, PLACED_LEVEL = 4,
  PLACED_TURNED = 5, PLACED_ANGLE = 6, PLACED_SIZE = 7, PLACED_RESIZES = 8, PLACED_CUT_COUNT = 9,
  CUT_NUMBERS = 3,          /* the line, the piece, and its first column left out */
  DRAWN_PLACE_NUMBERS = 3,  /* whether drawn, and where */
};

/* The +count+ sprites at +placed+ as field +name+, and the slices left out of them as +cuts_name+.
 * Read back, their slices are added to left_out after any already there, so the two lists of
 * sprites each keep their own. */
static void visit_placed_objects(const char *name, const char *cuts_name, placed_object *placed, int32_t count) {
  int reading = rg_state_reading();
  int64_t *numbers = rg_state_room((int64_t)count * PLACED_STATE_NUMBERS);
  for (int32_t i = 0; !reading && i < count; i++) {
    const placed_object *p = &placed[i];
    int64_t kept[PLACED_STATE_NUMBERS] = {p->sprite, p->image, p->x, p->y, p->level, p->turned, p->angle, p->size, p->resizes,
                                          p->cut_count};
    memcpy(numbers + (int64_t)i * PLACED_STATE_NUMBERS, kept, sizeof kept);
  }
  rg_state_numbers(name, numbers, count * PLACED_STATE_NUMBERS);

  int64_t cut_total = 0;
  for (int32_t i = 0; i < count; i++) {
    const int64_t *n = numbers + (int64_t)i * PLACED_STATE_NUMBERS;
    if (n[PLACED_SPRITE] < 0 || n[PLACED_SPRITE] >= RG_MAX_SPRITES || n[PLACED_IMAGE] < 0 ||
        n[PLACED_IMAGE] >= rg_game_picture_sizes[RG_SIZE_IMAGES] || n[PLACED_CUT_COUNT] < 0)
      rg_state_refuse_damaged("a sprite names a sprite or a picture the game does not have");
    cut_total += n[PLACED_CUT_COUNT];
  }
  if (cut_total > MAX_LEFT_OUT - (reading ? left_out_count : 0)) rg_state_refuse_damaged("more slices of sprites are left out than can be");

  int64_t *cuts = rg_state_room(cut_total * CUT_NUMBERS), at = 0;
  for (int32_t i = 0; !reading && i < count; i++)
    for (int32_t j = placed[i].cut_from; j < placed[i].cut_from + placed[i].cut_count; j++, at += CUT_NUMBERS) {
      cuts[at] = left_out[j].line;
      cuts[at + 1] = left_out[j].piece;
      cuts[at + 2] = left_out[j].from;
    }
  rg_state_numbers(cuts_name, cuts, (int32_t)(cut_total * CUT_NUMBERS));

  at = 0;
  for (int32_t i = 0; reading && i < count; i++) {
    const int64_t *n = numbers + (int64_t)i * PLACED_STATE_NUMBERS;
    placed[i] = (placed_object){(int32_t)n[PLACED_SPRITE], (int32_t)n[PLACED_IMAGE], (int32_t)n[PLACED_X], (int32_t)n[PLACED_Y],
                                (int32_t)n[PLACED_LEVEL], (int32_t)n[PLACED_TURNED], (int32_t)n[PLACED_ANGLE],
                                (int32_t)n[PLACED_SIZE], (int32_t)n[PLACED_RESIZES], left_out_count, (int32_t)n[PLACED_CUT_COUNT]};
    for (int64_t k = 0; k < n[PLACED_CUT_COUNT]; k++, at += CUT_NUMBERS)
      left_out[left_out_count++] = (left_out_piece){(int32_t)cuts[at], (int32_t)cuts[at + 1], (int32_t)cuts[at + 2]};
  }
  free(cuts);
  free(numbers);
}

/* rg_hook_visit_state: the sprites last put on screen and those kept for the picture's rebuild,
 * with the slices left out of each; where each was last drawn straight onto the picture; and the
 * layer of sprites over a painted picture (Computer::StateFields "sprites" and the rest). A layer
 * not up is written as nothing in front everywhere. */
static void rg_sprites_visit_state(void) {
  int64_t counts[] = {drawing_count, sprite_layer_count, over_picture_up};
  rg_state_numbers("sprites", counts, 3);
  if (counts[0] < 0 || counts[0] > RG_MAX_SPRITES || counts[1] < 0 || counts[1] > RG_MAX_SPRITES)
    rg_state_refuse_damaged("more sprites are on screen than there is room for");
  drawing_count = (int32_t)counts[0];
  sprite_layer_count = (int32_t)counts[1];
  over_picture_up = counts[2] != 0;

  if (rg_state_reading()) left_out_count = 0;
  visit_placed_objects("sprites.drawing", "sprites.drawing.cuts", drawing, drawing_count);
  visit_placed_objects("sprites.kept", "sprites.kept.cuts", sprite_layer, sprite_layer_count);

  int64_t *places = rg_state_room(RG_MAX_SPRITES * DRAWN_PLACE_NUMBERS);
  for (int32_t i = 0; i < RG_MAX_SPRITES; i++) {
    int32_t drawn = last_drawn[i].drawn;
    places[DRAWN_PLACE_NUMBERS * i] = drawn;
    places[DRAWN_PLACE_NUMBERS * i + 1] = drawn ? last_drawn[i].x : 0;
    places[DRAWN_PLACE_NUMBERS * i + 2] = drawn ? last_drawn[i].y : 0;
  }
  rg_state_numbers("sprites.drawn_places", places, RG_MAX_SPRITES * DRAWN_PLACE_NUMBERS);
  for (int32_t i = 0; i < RG_MAX_SPRITES; i++)
    last_drawn[i] = (drawn_place){places[DRAWN_PLACE_NUMBERS * i] != 0, (int32_t)places[DRAWN_PLACE_NUMBERS * i + 1],
                                  (int32_t)places[DRAWN_PLACE_NUMBERS * i + 2]};
  free(places);

  int64_t *front = rg_state_room(CELLS);
  for (int32_t at = 0; at < CELLS; at++) front[at] = over_picture_up ? over_picture[at] : RG_NOTHING_IN_FRONT;
  rg_state_numbers("sprites.over_picture", front, CELLS);
  for (int32_t at = 0; at < CELLS; at++) over_picture[at] = (uint16_t)front[at];
  free(front);
}
