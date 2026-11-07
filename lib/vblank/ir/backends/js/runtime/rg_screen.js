/*
 * The game's picture, drawn in software: the console's 240x160 screen as an array of colors, and
 * everything the game does to it. A port of the native runtime's rg_screen.c, function for
 * function, which is itself a port of the interpreter's picture (backends/reference.rb and
 * reference/framebuffer.rb) — each function names the interpreter's method it follows, because
 * that is what decides what is right here. See rg_screen.h for the layout of every array the
 * lowering writes (rg_game_backgrounds, rg_game_images, ...); this file reads them the same way.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest.
 *
 * Numbers here are positions and colors, never a game's own arithmetic, so they are plain
 * JavaScript numbers: a float holds every whole number this can reach exactly. Where C divides
 * whole numbers it truncates toward nought, and so does Math.trunc here; floor_div and floor_mod
 * round down, as Ruby's / and % do.
 */

const RG_CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;

const RG_BITMAP = 0, RG_TILED = 1, RG_ROTOZOOM = 2;

const RG_NOT_DRAWN = -1;
const RG_IMAGE_FIELDS = 3;
const RG_MAX_SPRITES = 512;
const RG_SOLID = -1;
const RG_NO_NAME = -1;
const RG_NOT_IN_BLOCKS = -1;
const RG_ST_AMOUNTS_WRITTEN = 0, RG_ST_ONE_AMOUNT = 1, RG_ST_HOLDS_A_SPRITE = 2, RG_ST_FIELDS = 3;
const RG_MAX_SEE_THROUGH = 16;
const RG_SEE_THROUGH = 0xFFFF;
const RG_NO_LAYER = -1;
const RG_NOT_PAINTED = -1;
const RG_RUN_TILES = 0, RG_RUN_WIDTH = 1, RG_RUN_HEIGHT = 2, RG_RUN_PLACES = 3, RG_RUN_FIRST_IMAGE = 4,
  RG_RUN_IMAGES = 5, RG_RUN_PLANES = 6, RG_RUN_FIELDS = 7;
const RG_RUN_IMAGE_FIELDS = 17;
const RG_SIZE_BACKGROUNDS = 0, RG_SIZE_DEPTHS = 1, RG_SIZE_ALWAYS_UP = 2, RG_SIZE_REBUILT_WHOLE = 3,
  RG_SIZE_SEE_THROUGH = 4, RG_SIZE_SCREEN_KINDS_CHANGE = 5, RG_SIZE_LARGEST_BLOCK = 6, RG_SIZE_RUNS = 7,
  RG_SIZE_RUN_PIXELS = 8, RG_SIZE_IMAGES = 9, RG_SIZE_SPRITES_OVER_PICTURE = 10;

/* Where choice number +which+ is in a row that holds a sprite's own first and then +others+ more. */
function rg_place_of_choice(which, others) { return which >= 0 && which < others ? which + 1 : 0; }

/* Two colors for a line of text, and the test that picks which. */
function rg_pick_color(showing, color, picked) { return showing !== 0 ? picked : color; }

/* --- small arithmetic --- */

function floor_div(a, b) { return Math.floor(a / b); }
function floor_mod(a, b) { return a - Math.floor(a / b) * b; }
function clamp_number(value, low, high) { return value < low ? low : (value > high ? high : value); }

/* TWO PAGES, OR ONE (Framebuffer#paged=). Drawing always lands on +pixels+ and the viewer always
 * reads +viewed+; with one page those are the same picture. */
const first_page = new Uint16Array(RG_CELLS), second_page = new Uint16Array(RG_CELLS);
let pixels = first_page;
let viewed = first_page;
const shown = new Uint16Array(RG_CELLS);

/* Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back under
 * a sprite (Reference#drawing_into). */
let target = first_page;

/* The part of the screen drawing is held inside, and the areas in force around it. */
let area = { in_force: 0, left: 0, top: 0, right: 0, bottom: 0 };
const outer_areas = [];
const AREAS_DEEP = 64;

let camera_x = 0, camera_y = 0;

/* The patches of picture saved under bitmap sprites, by buffer number. */
const NO_CELL = -1;
const saved_patches = [];

/* THE SCENERY WITH NOTHING ON IT (Reference @scene_fb). */
const scenery = new Uint16Array(RG_CELLS);
let scenery_kept = 0;

let held = 0;
let frames_begun = 0;
let kind = -1;
let owed = 0;
let repaints_painted = 0; /* how many times the whole view was built again (rg_screen_repaints_painted) */
/* The interpreter asks for a rebuild every time the scroll or the sprites are set. Here a setting
 * that moved nothing asks for nothing and only notes that it would have (rebuild_skipped), since
 * the picture is the one a rebuild would paint. That stops being so once the picture is touched:
 * something else has written to it, or the pages have changed over. So when the rebuild would be
 * painted, a skipped one with the picture touched is painted after all, whichever came first. */
let rebuild_skipped = 0;
let picture_touched = 0;
let backdrop = 0; /* the colour shown wherever nothing is drawn (Reference @backdrop) */
let current_scene = -1;

/* WHAT IS PAINTED FROM HERE ON IS FADED on its way in (Framebuffer @paint_toward), by the placed
 * fade in force: { table, fill } of the colours each colour goes through, or null to paint as drawn.
 * Set only while the view is rebuilt, for the things that fade reaches (fade_unless_left_as_drawn). */
let paint_fade = null;

/* A FILTER THE PICTURE IS READ THROUGH, handed over by a feature once a read (rg_hook_fade_filter,
 * rg_hook_dim_filter), so no feature is asked about a pixel. It is an object:
 *   table:      the colour shown for each of the 65536 values a cell can hold, indexed by its sixteen
 *               bits, in an Int32Array. It is filled as colours are looked up: -1 is a colour not
 *               worked out yet, which +fill(color)+ works out, stores and answers (once a colour for
 *               as long as the feature's state is the same, since a feature starts the table again
 *               when its state changes);
 *   everywhere: whether it applies to every pixel;
 *   rows:       when not, an Int32Array of three numbers a screen row, [from, to, inverted]: a pixel
 *               is changed when inverted XOR from <= x < to;
 *   remix:      whether a cell a see-through layer was mixed into is mixed again from its two sides,
 *               each read through the table (Framebuffer#shown_color). */

/* WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through). */
let mixing = 0;
let mixed_by = { painted: 0, under: 0 };

/* THE TWO COLORS EACH MIXED CELL WAS MIXED FROM (Framebuffer @mixed_tops). */
function new_mixed_sides() {
  return { is_mixed: new Uint8Array(RG_CELLS), tops: new Uint16Array(RG_CELLS), unders: new Uint16Array(RG_CELLS) };
}
const picture_mixes = new_mixed_sides(), scenery_mixes = new_mixed_sides();
let mixed_cells_by = { painted: 0, under: 0 };

/* THE PICTURE WITH NO SPRITES ON IT (Framebuffer @scenery). */
const picture_without_sprites = new Uint16Array(RG_CELLS);
let painting_sprite = 0;



/* --- the picture itself (Framebuffer) --- */

function on_screen(x, y) { return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT; }

function paintable(x, y) {
  if (!on_screen(x, y)) return false;
  return !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom);
}

function widened(channel) { return (channel << 3) | (channel >> 2); }

/* Framebuffer#mix_see_through */
function mixed_with_under(color, under, by) {
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    const have = widened((color >> (5 * channel)) & 0x1F), below = widened((under >> (5 * channel)) & 0x1F);
    const mix = Math.trunc((have * by.painted + below * by.under) / 16);
    out |= ((mix > 255 ? 255 : mix) >> 3) << (5 * channel);
  }
  return out;
}

/* Framebuffer#darkened_by_display: done in the channel's own byte as the interpreter does it. */
function darkened_by_display(color, steps) {
  if (steps === 0) return color;
  let packed = 0;
  for (let channel = 0; channel < 3; channel++) {
    const shift = channel * 5;
    const placed = widened((color >> shift) & 0x1F) * 2 ** (channel * 8);
    const kept = Math.floor((placed - Math.trunc((placed * steps) / 16)) / 2 ** (channel * 8));
    packed |= (kept >> 3) << shift;
  }
  return packed;
}

/* Framebuffer#apply_placed_fade: a color as it is painted while a placed fade reaches it, through
 * the colour table the fade handed over (paint_fade; a miss in it is -1, which the table's +fill+
 * works out, stores and answers). The color is masked to the sixteen bits a cell holds either way. */
function faded_as_painted(color) {
  const masked = color & 0xFFFF;
  if (!paint_fade) return masked;
  const faded = paint_fade.table[masked];
  return faded < 0 ? paint_fade.fill(masked) : faded;
}

function mixes_of(page) {
  if (page === pixels) return picture_mixes;
  return page === scenery ? scenery_mixes : null;
}

/* Framebuffer#blend_into_cell */
function into_cell(color, under, page, at) {
  const painted = faded_as_painted(color);
  const kept = mixes_of(page);
  if (kept) {
    kept.is_mixed[at] = mixing;
    if (mixing) {
      kept.tops[at] = painted;
      kept.unders[at] = under;
    }
  }
  return mixing ? mixed_with_under(painted, under, mixed_by) : painted;
}

/* Reference#see_through_sprites?, worked out once. */
let sprites_seen_through_answer = -1;
function sprites_seen_through() {
  if (sprites_seen_through_answer >= 0) return sprites_seen_through_answer;
  sprites_seen_through_answer = 0;
  for (let layer = 0; layer < rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; layer++) {
    if (rg_game_see_through[layer * RG_ST_FIELDS + RG_ST_HOLDS_A_SPRITE]) sprites_seen_through_answer = 1;
  }
  return sprites_seen_through_answer;
}

function keeps_picture_without_sprites() { return target !== scenery && sprites_seen_through(); }

/* A LAYER A FEATURE PAINTS INTO AS IT IS, while one is handed over (paint_onto_plain_layer, null to
 * give it back): a screen's worth of cells, each painted pixel stored whole there and nowhere else,
 * with no area, mix or fade. null while drawing goes to the picture, so a pixel painted then costs
 * one test. */
let plain_layer = null;

function paint_onto_plain_layer(layer) { plain_layer = layer; }

/* What a cell of a layer in front of the picture holds where nothing is in front
 * (rg_hook_front_layer): no colour is that number, since a colour is fifteen bits. */
const RG_NOTHING_IN_FRONT = 0x8000;

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. */
function set_pixel(x, y, color) {
  if (plain_layer) {
    if (on_screen(x, y)) plain_layer[y * RG_SCREEN_WIDTH + x] = color;
    return;
  }
  if (!paintable(x, y)) return;
  picture_touched = 1;
  const at = y * RG_SCREEN_WIDTH + x;
  const kept = keeps_picture_without_sprites();
  const under = kept && painting_sprite ? picture_without_sprites : target;
  const painted = into_cell(color, under[at], target, at);
  target[at] = painted;
  if (kept && !painting_sprite) picture_without_sprites[at] = painted;
}

/* Framebuffer#fill_rect */
function fill_cells(x, y, width, height, color) {
  const left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  let right = x + width, bottom = y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  for (let py = top; py < bottom; py++) {
    for (let px = left; px < right; px++) set_pixel(px, py, color);
  }
}

/* Framebuffer#clear */
function clear_to(color) {
  if (area.in_force) {
    fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color);
    return;
  }
  picture_touched = 1;
  const painted = faded_as_painted(color);
  target.fill(painted);
  const kept = mixes_of(target);
  if (kept) kept.is_mixed.fill(0);
  if (!keeps_picture_without_sprites()) return;
  picture_without_sprites.fill(painted);
}

function rg_screen_clear(color) { clear_to(color); }
function rg_screen_fill_rect(x, y, width, height, color) { fill_cells(x, y, width, height, color); }

function rg_screen_inside(x, y, width, height) {
  if (outer_areas.length >= AREAS_DEEP) rg_fault(`more than ${AREAS_DEEP} \`inside\` blocks are open at once`);
  outer_areas.push(area);
  area = { in_force: 1, left: x, top: y, right: x + width, bottom: y + height };
}

function rg_screen_inside_ended() { area = outer_areas.pop(); }

function rg_screen_camera(x, y) {
  camera_x = x;
  camera_y = y;
}

function rg_screen_camera_x() { return camera_x; }
function rg_screen_camera_y() { return camera_y; }

/* Framebuffer#paged= */
function show_pages(two) {
  if (two === (pixels !== viewed ? 1 : 0)) return;
  if (!two) {
    viewed = pixels;
    return;
  }
  viewed = pixels === first_page ? second_page : first_page;
  viewed.fill(0);
}

/* Reference#exec_save_region */
function rg_patch_save(buffer, width, height, x, y) {
  if (!saved_patches[buffer]) saved_patches[buffer] = new Int32Array(Math.max(width * height, 1));
  const patch = saved_patches[buffer];
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const px = x + col, py = y + row;
      patch[row * width + col] = on_screen(px, py) ? pixels[py * RG_SCREEN_WIDTH + px] : NO_CELL;
    }
  }
}

/* Reference#exec_restore_region */
function rg_patch_restore(buffer, width, height, x, y) {
  const patch = saved_patches[buffer];
  if (!patch) return;
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const color = patch[row * width + col];
      if (color !== NO_CELL) set_pixel(x + col, y + row, color);
    }
  }
}

function rg_screen_pixel(x, y, color) { set_pixel(x, y, color); }

/* Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. */
function rg_screen_points(x, y, color, points, count, first = 0) {
  for (let i = 0; i < count; i++) set_pixel(x + points[2 * (first + i)], y + points[2 * (first + i) + 1], color);
}

/* Reference#exec_draw_digit */
function rg_screen_digit(value, x, y, color, points, starts) {
  if (value < 0 || value > 9) return;
  rg_screen_points(x, y, color, points, starts[value + 1] - starts[value], starts[value]);
}

/* --- see-through layers --- */

function see_through_layers() { return rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; }
function see_through_field(layer, field) { return rg_game_see_through[layer * RG_ST_FIELDS + field]; }

const NOBODY_ASKED = -1;
let asked_layer = NOBODY_ASKED;
const answered = { shows: 0, behind: 0 };

function rg_see_through_asked(layer) { return layer === asked_layer ? 1 : 0; }

function rg_see_through_answer(shows, behind) {
  answered.shows = shows;
  answered.behind = behind;
}

/* IR::SeeThrough.nearest_steps and .floor_steps */
function nearest_sixteenths(amount) { return clamp_number(floor_div(amount * 16 + 50, 100), 0, 16); }
function whole_sixteenths(amount) { return clamp_number(floor_div(amount * 16, 100), 0, 16); }

/* Reference#live_see_through_weights */
function shares_now(layer) {
  asked_layer = layer;
  rg_game_see_through_amounts();
  asked_layer = NOBODY_ASKED;
  if (see_through_field(layer, RG_ST_ONE_AMOUNT)) {
    const under = whole_sixteenths(answered.behind);
    return { painted: 16 - under, under };
  }
  return { painted: nearest_sixteenths(answered.shows), under: nearest_sixteenths(answered.behind) };
}

const owed_shares = [], told_shares = [];
for (let i = 0; i < RG_MAX_SEE_THROUGH; i++) {
  owed_shares.push({ kept: 0, at: { painted: 0, under: 0 } });
  told_shares.push({ kept: 0, at: { painted: 0, under: 0 } });
}

/* Reference#layer_has_anything?: scenery showing now (rg_hook_layer_holds_scenery), or a sprite
 * drawn in that layer. */
function layer_holds_anything(layer) {
  return see_through_field(layer, RG_ST_HOLDS_A_SPRITE) || rg_hook_layer_holds_scenery(layer);
}

/* Reference#capture_see_through_weights */
function keep_shares_for_owed_rebuild() {
  for (let layer = 0; layer < see_through_layers(); layer++) {
    owed_shares[layer].kept = !see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) && layer_holds_anything(layer) ? 1 : 0;
    if (owed_shares[layer].kept) owed_shares[layer].at = shares_now(layer);
  }
}

function forget_kept_shares() {
  for (let layer = 0; layer < see_through_layers(); layer++) owed_shares[layer].kept = 0;
}

/* Reference#set_see_through_for, for scenery. A fade that holds the display's blend
 * (rg_hook_blend_held_by_fade, Reference#fading?) leaves the layer solid. */
function mix_as_layer(layer) {
  painting_sprite = 0;
  mixing = layer !== RG_SOLID && !rg_hook_blend_held_by_fade() ? 1 : 0;
  if (mixing) mixed_by = mixed_cells_by = owed_shares[layer].kept ? owed_shares[layer].at : shares_now(layer);
}

function mix_nothing() {
  mixing = 0;
  painting_sprite = 0;
}

/* WHAT THE GAME HAS PAINTED (Reference @bitmaps, for the tiles and pictures of a run). */
const RUN_TILE_SIDE = 8, RUN_TILE_PIXELS = RUN_TILE_SIDE * RUN_TILE_SIDE, PLACES_IN_RUN_COLORS = 16;
let painted_places = null;

function run_field(run, field) { return rg_game_tile_runs[RG_RUN_FIELDS * run + field]; }

/* Where a run's places start in painted_places. */
function places_of(run) {
  if (!painted_places) painted_places = new Uint8Array(rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1);
  return run_field(run, RG_RUN_PLACES);
}

function painted_places_at(at) { return painted_places[at]; }

/* Reference#request_repaint (rg_hook_repaint_requested is where a feature hears of it) */
function request_repaint() {
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  rg_hook_repaint_requested();
  owed = 1;
  keep_shares_for_owed_rebuild();
}

function rg_screen_request_rebuild() { request_repaint(); }

/* Reference#painted_screen? */
function painted_screen() { return kind < 0 || kind === RG_BITMAP; }

/* Reference#exec_see_through */
function rg_see_through_told(layer) {
  const now = shares_now(layer);
  const told = told_shares[layer];
  if (told.kept && told.at.painted === now.painted && told.at.under === now.under) return;
  told_shares[layer] = { kept: 1, at: now };
  request_repaint();
}

/* A rebuild that request_repaint would have owed, left out because nothing moved. */
function skip_repaint() {
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  rebuild_skipped = 1;
}

/* IR::Affine.matrix */
function affine_matrix(angle, size) {
  const scale_one = rg_game_turn_rules[0], one_th = rg_game_turn_rules[1];
  const most = rg_game_turn_rules[2], least_size = rg_game_turn_rules[3];
  const scale = size < least_size ? least_size : size;
  let recip = Math.trunc((scale_one * one_th) / scale);
  if (recip > most) recip = most;
  return [floor_div(rg_game_sines[angle + 90] * recip, one_th), floor_div(rg_game_sines[angle] * recip, one_th)];
}


/* --- sprites --- */

/* The images the game has painted, by image number (Reference#store_run_picture). */
const painted_images = [];

/* One picture: its pixels (an array and where in it they start), and its size. */
function picture_of(image) {
  const info = RG_IMAGE_FIELDS * image;
  const painted = painted_images[image];
  return painted ? { pixels: painted, start: 0, width: rg_game_images[info + 1], height: rg_game_images[info + 2] }
    : { pixels: rg_game_image_pixels, start: rg_game_images[info], width: rg_game_images[info + 1], height: rg_game_images[info + 2] };
}

/* Reference#run_tile_places */
function read_tile_places(list, which, planes, places, into) {
  if (planes > 0) {
    const first = which * planes * 8;
    for (let pixel = 0; pixel < RUN_TILE_PIXELS; pixel++) {
      let place = 0;
      for (let plane = 0; plane < planes; plane++) {
        const index = first + (plane >> 1) * 16 + (pixel >> 3) * 2 + (plane & 1);
        const byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
        place |= ((byte >> (7 - (pixel & 7))) & 1) << plane;
      }
      places[into + pixel] = place;
    }
    return;
  }
  for (let at = 0; at < RUN_TILE_PIXELS / 2; at++) {
    const index = which * (RUN_TILE_PIXELS / 2) + at;
    const byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
    places[into + 2 * at] = byte & 0x0F;
    places[into + 2 * at + 1] = byte >> 4;
  }
}

/* Reference#copy_run_tiles */
function rg_tiles_copy(run, list) {
  const start = places_of(run);
  const width = run_field(run, RG_RUN_WIDTH), height = run_field(run, RG_RUN_HEIGHT);
  if (width === 0) {
    for (let which = 0; which < run_field(run, RG_RUN_TILES); which++) {
      read_tile_places(list, which, run_field(run, RG_RUN_PLANES), painted_places, start + which * RUN_TILE_PIXELS);
    }
    return;
  }
  const across = Math.trunc(width / RUN_TILE_SIDE);
  const tile = new Uint8Array(RUN_TILE_PIXELS);
  for (let which = 0; which < across * Math.trunc(height / RUN_TILE_SIDE); which++) {
    read_tile_places(list, which, run_field(run, RG_RUN_PLANES), tile, 0);
    const left = (which % across) * RUN_TILE_SIDE, top = Math.trunc(which / across) * RUN_TILE_SIDE;
    for (let i = 0; i < RUN_TILE_PIXELS; i++) {
      painted_places[start + (top + Math.trunc(i / RUN_TILE_SIDE)) * width + left + (i % RUN_TILE_SIDE)] = tile[i];
    }
  }
  paint_run_images(run);
}

/* Every image that is a painted picture's run made again from its places, each in its own colors. */
function paint_run_images(run) {
  const start = places_of(run);
  const area = run_field(run, RG_RUN_WIDTH) * run_field(run, RG_RUN_HEIGHT);
  for (let i = 0; i < run_field(run, RG_RUN_IMAGES); i++) {
    const shown_as = (run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS;
    const image = rg_game_run_images[shown_as];
    if (!painted_images[image]) painted_images[image] = new Int16Array(area);
    const into = painted_images[image];
    for (let at = 0; at < area; at++) into[at] = rg_game_run_images[shown_as + 1 + painted_places[start + at]];
  }
}

/* rg_screen.c's rg_tile_pose_load (Reference#exec_load_sprite_tiles, for one pose). */
function rg_tile_pose_load(run, pieces, piece_count, table, _kept, at, to, count) {
  const start = places_of(run);
  const width = run_field(run, RG_RUN_WIDTH);
  for (let piece = 0; piece < piece_count; piece++) {
    const dx = pieces[3 * piece], dy = pieces[3 * piece + 1], tile = pieces[3 * piece + 2];
    if (tile < to || tile >= to + count) continue;
    const first = (at + tile - to) * (RUN_TILE_PIXELS / 2);
    for (let byte_at = 0; byte_at < RUN_TILE_PIXELS / 2; byte_at++) {
      const byte = table[first + byte_at] & 0xFF;
      const row = Math.trunc(byte_at / (RUN_TILE_SIDE / 2)), col = (byte_at % (RUN_TILE_SIDE / 2)) * 2;
      painted_places[start + (dy + row) * width + dx + col] = byte & 0x0F;
      painted_places[start + (dy + row) * width + dx + col + 1] = byte >> 4;
    }
  }
  paint_run_images(run);
}

/* Reference#blit_image */
function blit_image(image, x, y) {
  const art = picture_of(image);
  for (let row = 0; row < art.height; row++) {
    for (let col = 0; col < art.width; col++) {
      const color = art.pixels[art.start + row * art.width + col];
      if (color !== RG_NOT_DRAWN) set_pixel(x + col, y + row, color);
    }
  }
}

function rebuilt_whole() { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

function rg_screen_blit(image, x, y) { blit_image(image, x, y); }

function rg_screen_blit_pose(poses, count, pose, x, y) {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

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

/* Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or null
 * when it crosses no row's middle. +at+ is x, u, v, w and shade where it crosses its first row, +step+ each one's
 * step a row. */
function face_edge_of(top, bottom) {
  const first_row = rg_shr(rg_add(top[1], 7), 4);
  const past_row = rg_shr(rg_add(bottom[1], 7), 4);
  if (first_row >= past_row) return null;
  const along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]));
  const into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4);
  const parts = [rg_shl(rg_sub(bottom[0], top[0]), 12), rg_sub(bottom[2], top[2]), rg_sub(bottom[3], top[3]),
                 rg_sub(bottom[4], top[4]), rg_sub(bottom[5], top[5])];
  const starts = [rg_shl(top[0], 12), top[2], top[3], top[4], top[5]];
  return {
    first_row, past_row,
    at: parts.map((part, k) => rg_add(starts[k], rg_mul_fix(part, into, 24))),
    step: parts.map((part) => rg_mul_fix(part, along_row, 24)),
  };
}

/* IR::Reciprocals: 2**40 over each number of eleven bits with the top one set. */
const FACE_RECIPROCALS = Array.from({ length: 1024 }, (_, leading) => Math.floor(2 ** 40 / (1024 + leading)));

/* IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26. */
function face_distance(w) {
  if (w < 4096) w = 4096;
  let moved = 0;
  while ((w >> moved) >= 2048) moved++;
  return FACE_RECIPROCALS[(w >> moved) - 1024] >> (moved - 2);
}

/* Reference#place_in_perspective */
function face_place_in_perspective(from, steps, along) {
  const over_u = rg_add(from[1], rg_mul(steps[0], along));
  const over_v = rg_add(from[2], rg_mul(steps[1], along));
  const distance = face_distance(rg_add(from[3], rg_mul(steps[2], along)));
  return [rg_mul_fix(over_u, distance, 14), rg_mul_fix(over_v, distance, 14)];
}

/* Reference::Shade's places: for each shading drawn with, where each colour stands in its list of
 * colours. */
const SHADING_PLACES = new WeakMap();

/* Reference::Shade#color_at: the colour +color+ becomes at +shade+ (its level in the top sixteen
 * bits). A colour not in the shading's list stays as it is. */
function shaded_color(shading, color, shade) {
  const colors = shading[1];
  let places = SHADING_PLACES.get(shading);
  if (!places) {
    places = new Map();
    for (let place = colors - 1; place >= 0; place--) places.set(shading[2 + place], place);
    SHADING_PLACES.set(shading, places);
  }
  const place = places.get(color);
  if (place === undefined) return color;
  return shaded_place(shading, place, shade);
}

/* Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
 * +shade+. */
function shaded_place(shading, place, shade) {
  const colors = shading[1];
  const level = rg_shr(shade, 16);
  return shading[2 + shading[2 + colors + level * colors + place]];
}

/* Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w, shade), in
 * perspective every +spans+ pixels (none when nought), each pixel through +shading+ when lit.
 * +numbers+ is, for a picture given as numbers into the shading's colours, those numbers as a
 * picture of the same size; null for any other. */
function face_row(row, from, to, left, right, art, numbers, spans, shading) {
  const start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16);
  const stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16);
  const count = rg_sub(stop, start);
  if (count <= 0) return;
  if (shading) {
    // Reference::Shade#held_row_end
    from[4] = clamp_number(from[4], 0, rg_shl(shading[0], 16) - 1);
    to[4] = clamp_number(to[4], 0, rg_shl(shading[0], 16) - 1);
  }
  const steps = [1, 2, 3, 4].map((part) => rg_div(rg_sub(to[part], from[part]), count));
  const first = start > left ? start : left;
  const past = stop < right ? stop : right;
  let near_at = -1;
  let near = null;
  let far = null;
  for (let x = first; x < past; x++) {
    const along = rg_sub(x, start);
    let u;
    let v;
    if (spans === 0) {
      u = rg_add(from[1], rg_mul(steps[0], along));
      v = rg_add(from[2], rg_mul(steps[1], along));
    } else {
      // Reference#place_between
      const near_along = Math.floor(along / spans) * spans;
      const far_along = near_along + spans < count ? near_along + spans : count;
      if (near_along !== near_at) {
        near = face_place_in_perspective(from, steps, near_along);
        far = face_place_in_perspective(from, steps, far_along);
        near_at = near_along;
      }
      u = rg_add(near[0], rg_mul(rg_div(rg_sub(far[0], near[0]), far_along - near_along), along - near_along));
      v = rg_add(near[1], rg_mul(rg_div(rg_sub(far[1], near[1]), far_along - near_along), along - near_along));
    }
    const across = rg_and(rg_shr(u, 16), art.width - 1);
    const down = rg_and(rg_shr(v, 16), art.height - 1);
    let color = art.pixels[art.start + down * art.width + across];
    if (color === RG_NOT_DRAWN) continue;
    if (shading) {
      const shade = rg_add(from[4], rg_mul(steps[3], along));
      color = numbers ? shaded_place(shading, numbers.pixels[numbers.start + down * art.width + across], shade)
                      : shaded_color(shading, color, shade);
    }
    set_pixel(x, row, color);
  }
}

/* The most corners a face has (Nodes::FillFace::MOST_CORNERS). */
const FACE_MOST_CORNERS = 8;

/* Reference#exec_fill_face */
function rg_screen_face(pictures, picture_count, picture, corner_list, corner_count, left, top, right, bottom, spans,
                        shading) {
  if (corner_count > FACE_MOST_CORNERS) corner_count = FACE_MOST_CORNERS;
  if (corner_count < 3) return;
  if (shading[0] === 0) shading = null;
  const corners = [];
  for (let k = 0; k < corner_count; k++) {
    const corner = [0, 1, 2, 3, 4, 5].map((field) => rg_list_get(corner_list, k * 6 + field));
    // Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels
    if (shading) corner[5] = rg_mul(clamp_number(corner[5], 0, 0xFFFF), shading[0]);
    if (spans !== 0) {
      // Reference::FaceEdges.in_perspective
      corner[2] = rg_mul_fix(corner[2], corner[4], 28);
      corner[3] = rg_mul_fix(corner[3], corner[4], 28);
    }
    corners.push(corner);
  }
  const image = pictures[clamp_number(picture, 0, picture_count - 1)];
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  const edges = [];
  for (let k = 0; k < corner_count; k++) {
    const a = corners[k];
    const b = corners[(k + 1) % corner_count];
    if (a[1] === b[1]) continue;
    const edge = a[1] < b[1] ? face_edge_of(a, b) : face_edge_of(b, a);
    if (edge) edges.push(edge);
  }
  if (edges.length === 0) return;
  let first = 2147483647;
  let past = -2147483648;
  for (const edge of edges) {
    if (edge.first_row < first) first = edge.first_row;
    if (edge.past_row > past) past = edge.past_row;
  }
  if (first < top) first = top;
  if (past > bottom) past = bottom;
  const art = picture_of(image);
  // After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
  // into the shading's colours, or -1 for a picture of colours.
  let numbers = null;
  if (shading) {
    const numbered = shading[2 + shading[1] + shading[0] * shading[1] + clamp_number(picture, 0, picture_count - 1)];
    if (numbered >= 0) numbers = picture_of(numbered);
  }
  for (let row = first; row < past; row++) {
    let from = [2147483647, 0, 0, 0, 0];
    let to = [-2147483648, 0, 0, 0, 0];
    let crossing = 0;
    for (const edge of edges) {
      if (row < edge.first_row || row >= edge.past_row) continue;
      const rows = rg_sub(row, edge.first_row);
      const at = edge.at.map((start, part) => rg_add(start, rg_mul(edge.step[part], rows)));
      crossing++;
      // the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      if (at[0] < from[0]) from = at;
      if (at[0] >= to[0]) to = at;
    }
    if (crossing >= 2) face_row(row, from, to, left, right, art, numbers, spans, shading);
  }
}


/* Reference#sprites: what the game last put on screen, which stays as it was put until the game next
 * sets its sprites. The headless runners read it for every game, so these stay here, and answer
 * through the hooks: none for a game with no sprites. */
function rg_screen_drawn_count() { return rg_hook_drawn_count(); }

function rg_screen_drawn_sprite(place) { return rg_hook_drawn_sprite(place); }

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

/* The fade half of Reference#set_blend_for, for the thing about to be painted: what is painted from
 * here on goes through the colour table a placed fade in force asks for it (rg_hook_paint_fade_for),
 * or as drawn where there is none. +fade_place+ is how far forward the thing's layer is
 * (RG_BG_FADE_PLACE, rg_game_sprite_fade_places), or RG_NO_LAYER for a thing every placed fade
 * reaches and for the backdrop, which is behind everything. */
function fade_unless_left_as_drawn(fade_place) { paint_fade = rg_hook_paint_fade_for(fade_place); }

function fade_nothing() { paint_fade = null; }

/* Back to front: the backdrop, then each level's scenery and sprites (rg_hook_paint_level, scenery
 * first), with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending). */
function repaint_view() {
  repaints_painted++;
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(backdrop);
  rg_hook_repaint_began();
  const levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (let level = 0; level < levels; level++) {
    rg_hook_paint_level(level);
  }
  rg_hook_repaint_ending();
  mix_nothing();
  fade_nothing();
  picture_touched = 0;
}

/* Reference#paint_owed_repaint */
function rg_screen_paint_owed_rebuild() {
  const skipped_and_touched = rebuild_skipped && picture_touched;
  rebuild_skipped = 0;
  if (owed || skipped_and_touched) {
    owed = 0;
    repaint_view();
    forget_kept_shares();
  }
  rg_hook_rebuild_checked();
}

/* --- screens and scenes --- */

function rg_screen_hold(value) { held = value; }

/* Whether the end of a pass is placing the frame's writes (Reference @placing_at_pass_end): set by
 * every game on a console that places them there, read by what a write placed then leaves alone
 * (a background that pass put up still shows from its corner). */
let placing_at_pass_end = 0;

function rg_screen_placing_at_pass_end(on) {
  placing_at_pass_end = on;
}

function rg_screen_frame_started() {
  held = 0;
  frames_begun = 1;
}

/* The top of Reference#advance_frame: a tear-free screen trades its pages. */
function rg_screen_frame_ended() {
  rg_hook_frame_ended();
  if (pixels === viewed) return;
  rg_screen_paint_owed_rebuild();
  const finished = pixels;
  pixels = viewed;
  viewed = finished;
  target = pixels;
  picture_touched = 1; // the page handed over was built before the one just shown
  rg_game_sprites_over_picture(); // Reference#advance_frame: placed with the page published
}

/* rg_screen.c's show_backdrop */
function show_backdrop(color) {
  if (color < 0 || color === backdrop) return;
  backdrop = color;
  scenery_kept = 0;
  if (rg_hook_scenery_up()) request_repaint();
  else clear_to(backdrop);
}

/* Reference#exec_screen */
function rg_screen_set(new_kind, two_pages, new_backdrop) {
  const crossing = kind >= 0 && kind !== new_kind;
  if (crossing) {
    if (new_backdrop >= 0) backdrop = new_backdrop;
    clear_to(backdrop);
    scenery_kept = 0;
  } else {
    show_backdrop(new_backdrop);
  }
  kind = new_kind;
  show_pages(two_pages);
  rg_hook_screen_set(); // a tint in force is mixed this screen's way
  if (!crossing) return 0;
  rg_hook_screen_crossed(new_kind);
  return new_kind !== RG_BITMAP ? 1 : 0;
}

/* Reference#cross_to_scene_screen */
function rg_screen_cross_to(new_kind, two_pages, new_backdrop) {
  if (kind >= 0 && kind !== new_kind) return rg_screen_set(new_kind, two_pages, new_backdrop);
  show_backdrop(new_backdrop);
  return 0;
}

/* rg_screen.c's rg_screen_show_backdrop */
function rg_screen_show_backdrop(color) { show_backdrop(color); }

function rg_scene_enter(scene) { current_scene = scene; }

/* Whether the last scene to take over took any scenery down. */
let scenery_taken_down = 0;

/* The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes
 * down (rg_hook_scene_take_down). */
function rg_scene_take_down(brings_scenery) { scenery_taken_down = rg_hook_scene_take_down(brings_scenery); }

/* Reference#redraw_sprites_over_arrived_scenery */
function rg_scene_redraw_sprites(brings_scenery) {
  if (!brings_scenery && !scenery_taken_down) return;
  if (painted_screen() || !rg_hook_any_sprite_kept()) return;
  request_repaint();
}

/* --- reading it back --- */

function rg_screen_two_pages() { return pixels !== viewed ? 1 : 0; }

function rg_screen_repaints_painted() { return repaints_painted; }

/* Framebuffer#to_a */
function rg_screen_stored() {
  rg_screen_paint_owed_rebuild();
  return viewed;
}

/* Framebuffer#displayed: the picture as a console that keeps fewer than five bits of a channel shows
 * it, each channel's top bits repeated to widen it back to five. */
function keep_console_colors() {
  if (RG_COLOR_BITS >= 5) return;
  const lost = 5 - RG_COLOR_BITS, kept_mask = (1 << RG_COLOR_BITS) - 1;
  for (let at = 0; at < shown.length; at++) {
    let kept = 0;
    for (let channel = 0; channel <= 10; channel += 5) {
      const level = (shown[at] >> (channel + lost)) & kept_mask;
      kept |= ((level << lost) | (level >> (RG_COLOR_BITS - lost))) << channel;
    }
    shown[at] = kept;
  }
}

/* Does the filter's row say it changes the pixel at column +x+? A filter's rows are flat, three
 * numbers a screen row [from, to, inverted]: a pixel is changed when inverted XOR from <= x < to. */
function filter_row_covers(rows, row, x) { return (rows[row + 2] !== 0) !== (x >= rows[row] && x < rows[row + 1]); }

/* Framebuffer#shown and #pixel: each pixel read from where a feature says it is read from
 * (rg_hook_shown_columns, rg_hook_shown_row), or its own place, with the layer a feature shows in
 * front of the picture laid over it (rg_hook_front_layer, asked once a read), then through the fade
 * or tint and the light where those reach it, and white for a held display.
 *
 * The fade or tint and the light are filters (shown_filter) a feature hands over once a read
 * (rg_hook_fade_filter, rg_hook_dim_filter), and the loop below only reads the tables they hold: a
 * colour not looked up yet is -1 there, and the filter's +fill+ works it out, stores it and answers
 * it, once a colour for as long as the state is the same. */
function rg_screen_shown() {
  rg_screen_paint_owed_rebuild();
  const columns = rg_hook_shown_columns();
  const front = rg_hook_front_layer();
  const fade = rg_hook_fade_filter();
  const dim = rg_hook_dim_filter();
  for (let y = 0; y < RG_SCREEN_HEIGHT; y++) {
    const from_y = rg_hook_shown_row(y) + camera_y;
    const fade_covers = fade && !fade.everywhere;
    const dim_covers = dim && !dim.everywhere;
    for (let x = 0; x < RG_SCREEN_WIDTH; x++) {
      const fade_here = fade && (!fade_covers || filter_row_covers(fade.rows, y * 3, x));
      const in_front = front ? front[y * RG_SCREEN_WIDTH + x] : RG_NOTHING_IN_FRONT;
      let color;
      if (in_front !== RG_NOTHING_IN_FRONT) {
        // a sprite over the picture is not in blocks
        color = in_front;
        if (fade_here) {
          color = fade.table[in_front];
          if (color < 0) color = fade.fill(in_front);
        }
      } else {
        const from_x = (columns ? columns[x] : x) + camera_x;
        const at = from_y * RG_SCREEN_WIDTH + from_x;
        const stored = on_screen(from_x, from_y) ? viewed[at] : 0;
        if (fade && fade.remix && on_screen(from_x, from_y) && picture_mixes.is_mixed[at]) {
          // Framebuffer#shown_color: a mixed cell is mixed again from its two sides, each through the table
          let top = fade.table[picture_mixes.tops[at]];
          if (top < 0) top = fade.fill(picture_mixes.tops[at]);
          let under = fade.table[picture_mixes.unders[at]];
          if (under < 0) under = fade.fill(picture_mixes.unders[at]);
          color = mixed_with_under(top, under, mixed_cells_by);
        } else {
          color = stored;
          if (fade_here) {
            color = fade.table[stored];
            if (color < 0) color = fade.fill(stored);
          }
        }
      }
      if (dim && (!dim_covers || filter_row_covers(dim.rows, y * 3, x))) {
        const dimmed = dim.table[color];
        color = dimmed < 0 ? dim.fill(color) : dimmed;
      }
      shown[y * RG_SCREEN_WIDTH + x] = held ? 0x7FFF : color;
    }
  }
  keep_console_colors();
  return shown;
}
