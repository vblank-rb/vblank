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
const RG_FADE_WHOLE_SCREEN = 0, RG_FADE_INSIDE = 1, RG_FADE_OUTSIDE = 2;

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

let fade_white = 0, fade_steps = 0;
const TINT_NONE = 0, TINT_TOWARD = 1, TINT_COLOR = 2;
let tint_mode = TINT_NONE;
let tint_white = 0, tint_color = 0, tint_steps = 0, tint_by_display = 0;


/* A FADE PLACED IN THE STACK, while one is in force (Reference @fade_placed). */
let placed_fade = { in_force: 0, layer_place: RG_NO_LAYER, toward_white: 0, steps: 0 };
let fading_what_is_painted = 0;

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


/* The sprites on screen this frame: being set (drawing), and as the last rebuild draws them. */
let drawing = [];
let sprite_layer = [];

/* Where each sprite was last drawn straight onto the picture (Reference @obj_prev). */
const last_drawn = [];
for (let i = 0; i < RG_MAX_SPRITES; i++) last_drawn.push({ drawn: 0, x: 0, y: 0 });

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

/* Framebuffer#brightened_by_display */
function brightened_by_display(color, steps) {
  if (steps === 0) return color;
  let packed = 0;
  for (let channel = 0; channel < 3; channel++) {
    const shift = channel * 5, have = widened((color >> shift) & 0x1F);
    packed |= ((have + Math.trunc(((255 - have) * steps) / 16)) >> 3) << shift;
  }
  return packed;
}

function faded_by_display(color, white, steps) {
  return white ? brightened_by_display(color, steps) : darkened_by_display(color, steps);
}

function faded_as_painted(color) {
  if (!fading_what_is_painted) return color & 0xFFFF;
  return faded_by_display(color & 0xFFFF, placed_fade.toward_white, placed_fade.steps);
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

/* Sprites over a painted picture (rg_screen.c's over_picture): one color or NOTHING_OVER for each
 * place on the screen, in front of the picture. While +painting_over_picture+ is set, what set_pixel
 * paints lands here and nowhere else. */
const NOTHING_OVER = 0x8000;
const over_picture = new Uint16Array(RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT);
let over_picture_up = false, painting_over_picture = false;

/* Framebuffer#set_pixel */
function set_pixel(x, y, color) {
  if (painting_over_picture) {
    if (on_screen(x, y)) over_picture[y * RG_SCREEN_WIDTH + x] = color;
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

/* Reference#fading? */
function fade_takes_the_blend() {
  if (placed_fade.in_force) return placed_fade.steps > 0;
  return target !== scenery && fade_steps > 0;
}

/* Reference#set_see_through_for, for scenery */
function mix_as_layer(layer) {
  painting_sprite = 0;
  mixing = layer !== RG_SOLID && !fade_takes_the_blend() ? 1 : 0;
  if (mixing) mixed_by = mixed_cells_by = owed_shares[layer].kept ? owed_shares[layer].at : shares_now(layer);
}

/* ...for a sprite */
function mix_as_sprite(sprite) {
  mix_as_layer(rg_game_sprite_see_through[sprite]);
  painting_sprite = 1;
}

function mix_nothing() {
  mixing = 0;
  painting_sprite = 0;
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step. */
const WALK_STEPS = 256;
const WALK_PER_DISPLAY = 16;

/* Framebuffer#walked_toward */
function walked_toward(color, white, steps) {
  if (steps === 0) return color;
  /* FadeSteps.dimmed_levels, on a display that dims */
  const level = steps >= WALK_STEPS ? 0 : 15 - Math.trunc((steps * 15) / WALK_STEPS);
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    let c = (color >> (5 * channel)) & 0x1F;
    if (RG_CONSOLE_DIMS && !white) c = Math.trunc((2 * c * level + 15) / 30);
    else c = white ? c + Math.trunc(((31 - c) * steps) / WALK_STEPS) : c - Math.trunc((c * steps) / WALK_STEPS);
    out |= c << (5 * channel);
  }
  return out & 0xFFFF;
}

/* Framebuffer#mixed and #mixed_by_display */
function mixed(color, toward, steps, by_display) {
  if (steps === 0) return color;
  const keep = WALK_STEPS - steps;
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    const have = (color >> (5 * channel)) & 0x1F, want = (toward >> (5 * channel)) & 0x1F;
    if (by_display) {
      out |= (Math.trunc((widened(have) * keep + widened(want) * steps) / WALK_STEPS) >> 3) << (5 * channel);
    } else {
      out |= Math.trunc((have * keep + want * steps) / WALK_STEPS) << (5 * channel);
    }
  }
  return out & 0xFFFF;
}

/* Framebuffer#faded */
function faded_where(color, fade_here) {
  if (tint_mode === TINT_TOWARD && tint_by_display) return faded_by_display(color, tint_white, Math.trunc(tint_steps / WALK_PER_DISPLAY));
  if (tint_mode === TINT_TOWARD) return walked_toward(color, tint_white, tint_steps);
  if (tint_mode === TINT_COLOR) return mixed(color, tint_color, tint_by_display ? tint_steps - (tint_steps % WALK_PER_DISPLAY) : tint_steps, tint_by_display);
  if (!fade_here) return color;
  return faded_by_display(color, fade_white, fade_steps);
}

function faded(color) { return faded_where(color, 1); }

/* Framebuffer#shown_color */
function shown_color(at, stored, fade_here) {
  if (tint_mode === TINT_NONE || pixels !== viewed || !picture_mixes.is_mixed[at]) return faded_where(stored, fade_here);
  return mixed_with_under(faded(picture_mixes.tops[at]), faded(picture_mixes.unders[at]), mixed_cells_by);
}

let fade_side = RG_FADE_WHOLE_SCREEN;
const fade_area = [0, 0, 0, 0];

/* Framebuffer#fade_reaches? */
function fade_reaches(x, y) {
  if (fade_side === RG_FADE_WHOLE_SCREEN) return 1;
  const within = x >= fade_area[0] && x < fade_area[2] && y >= fade_area[1] && y < fade_area[3];
  return (fade_side === RG_FADE_INSIDE ? within : !within) ? 1 : 0;
}

/* Reference#exec_fade, through Framebuffer#fade_steps_to or #tint_steps_to */
function fade_to(placed, layer_place, toward_white, steps, walked) {
  const took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade = { in_force: placed, layer_place, toward_white, steps };
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    tint_by_display = tint_mixed_by_display();
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  const blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() !== took_the_blend;
  if (was_placed || placed || blend_changed_hands) request_repaint();
}

function rg_screen_fade(toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

function rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps) {
  fade_side = reaches;
  fade_area[0] = left;
  fade_area[1] = top;
  fade_area[2] = right;
  fade_area[3] = bottom;
  fade_to(0, RG_NO_LAYER, toward_white, steps, 0);
}

function rg_screen_fade_under(layer_place, toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#tint_by_display? */
function tint_mixed_by_display() { return painted_screen() && pixels === viewed && RG_CONSOLE_BLENDS ? 1 : 0; }

/* Reference#exec_tint */
function rg_screen_tint(color, steps) {
  const took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade.in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  tint_by_display = tint_mixed_by_display();
  fade_steps = 0;
  const blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() !== took_the_blend;
  if (was_placed || blend_changed_hands) request_repaint();
}

/* Backends::FadeSteps.steps */
function rg_fade_steps(amount, fraction_bits, walked) {
  const levels = walked ? WALK_STEPS : 16;
  if (fraction_bits < 0) {
    const sixteenths = whole_sixteenths(amount);
    return walked ? sixteenths * WALK_PER_DISPLAY : sixteenths;
  }
  return clamp_number(floor_div(amount * levels, 100 * 2 ** fraction_bits), 0, levels);
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

/* WHICH ROWS OF THE SCREEN THE BOX OF A TURNED SPRITE IS SHOWN ON (Reference::TurnedBox). */
const TURNED_BOX_LINES = 256;

function turned_box_line(top, row) {
  const line = floor_mod(top + row, TURNED_BOX_LINES);
  return line < RG_SCREEN_HEIGHT ? line : -1;
}

function turned_box_on_screen(top, width, height, resizes) {
  let first = 0, past = height * 2;
  if (!resizes) {
    const reach = whole_root(width * width + height * height) + 2;
    first = height - Math.trunc(reach / 2);
    past = first + reach;
  }
  return top + past > 0 && top + first < RG_SCREEN_HEIGHT;
}

/* Reference#blit_image_transformed */
function blit_image_turned(image, x, y, angle, size, resizes) {
  const art = picture_of(image);
  const width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(floor_mod(angle, 360), size);
  const left = x - Math.trunc(width / 2), top = y - Math.trunc(height / 2);
  if (!turned_box_on_screen(top, width, height, resizes)) return;
  for (let iy = 0; iy < height * 2; iy++) {
    const line = turned_box_line(top, iy);
    if (line < 0) continue;
    const dy = iy - height;
    for (let ix = 0; ix < width * 2; ix++) {
      const dx = ix - width;
      const from_x = floor_div(turn_cos * dx + turn_sin * dy, one_th) + Math.trunc(width / 2);
      const from_y = floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Math.trunc(height / 2);
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      const color = art.pixels[art.start + from_y * width + from_x];
      if (color !== RG_NOT_DRAWN) set_pixel(left + ix, line, color);
    }
  }
}

/* --- how many sprites a line of the screen shows (rg_screen.c's, Backends::SpriteLines) ---
 * rg_game_image_pieces: how tall a piece is, then where each image's pieces start, and there how
 * many, then each one's across and down. RG_SPRITE_PIECES_A_LINE is 0 where every piece is drawn. */
const PIECE_WIDTH = 8;

function pieces_start(image) { return rg_game_image_pieces[1 + image]; }

/* Reference#mark_slices_left_out: each sprite that loses slices to a crowded line keeps them as
 * +cuts+, [line, piece] each. The table lists them front-most first: the deepest level last, and
 * inside a level the one drawn last first. */
function mark_slices_left_out(placed) {
  for (const sprite of placed) sprite.cuts = null;
  if (RG_SPRITE_PIECES_A_LINE === 0 || placed.length === 0) return;
  const order = placed.map((_, at) => at).sort((a, b) => placed[b].level - placed[a].level || b - a);
  const taken = new Int32Array(RG_SCREEN_HEIGHT), tall = rg_game_image_pieces[0];
  for (const at of order) {
    const sprite = placed[at], start = pieces_start(sprite.image), cuts = [];
    for (let piece = 0; piece < rg_game_image_pieces[start]; piece++) {
      const left = sprite.x + rg_game_image_pieces[start + 1 + 2 * piece];
      const top = sprite.y + rg_game_image_pieces[start + 2 + 2 * piece];
      if (left <= -PIECE_WIDTH || left >= RG_SCREEN_WIDTH) continue;
      for (let line = Math.max(top, 0); line < Math.min(top + tall, RG_SCREEN_HEIGHT); line++) {
        if (taken[line]++ >= RG_SPRITE_PIECES_A_LINE) cuts.push([line, piece]);
      }
    }
    if (cuts.length > 0) sprite.cuts = cuts;
  }
}

/* SpriteLines.left_out_at?: left out where a piece left out of the line covers it and no piece
 * drawn there does. */
function left_out_at(placed, col, row, line) {
  const start = pieces_start(placed.image), tall = rg_game_image_pieces[0];
  let covered = false;
  for (let piece = 0; piece < rg_game_image_pieces[start]; piece++) {
    const across = rg_game_image_pieces[start + 1 + 2 * piece], down = rg_game_image_pieces[start + 2 + 2 * piece];
    if (col < across || col >= across + PIECE_WIDTH || row < down || row >= down + tall) continue;
    if (!placed.cuts.some(([l, p]) => l === line && p === piece)) return false;
    covered = true;
  }
  return covered;
}

/* Reference#blit_image with a sprite's slices left out. */
function blit_with_slices_left_out(placed) {
  const art = picture_of(placed.image);
  for (let row = 0; row < art.height; row++) {
    for (let col = 0; col < art.width; col++) {
      const color = art.pixels[art.start + row * art.width + col];
      if (color !== RG_NOT_DRAWN && !left_out_at(placed, col, row, placed.y + row)) set_pixel(placed.x + col, placed.y + row, color);
    }
  }
}

/* Reference#draw_object and #paint_snapshot_object */
function draw_placed(placed) {
  if (placed.turned) blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes);
  else if (placed.cuts) blit_with_slices_left_out(placed);
  else blit_image(placed.image, placed.x, placed.y);
}

/* Reference#paint_snapshot_object: as drawn unless a feature draws it its own way. */
function paint_kept_sprite(placed) {
  if (!rg_hook_paint_kept_sprite(placed)) draw_placed(placed);
}

function rebuilt_whole() { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* Reference#scene_framebuffer */
function keep_scenery() {
  if (scenery_kept) return;
  const outer = area;
  area = { in_force: 0, left: 0, top: 0, right: 0, bottom: 0 };
  target = scenery;
  clear_to(backdrop);
  rg_hook_stamp_scenery();
  target = pixels;
  area = outer;
  scenery_kept = 1;
}

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

/* The start of Reference#exec_present_objects */
function rg_objects_begin() {
  drawing = [];
  if (!rebuilt_whole()) keep_scenery();
}

function fault_unless_sprite(sprite) {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault(`sprite number ${sprite} is not one of the ${RG_MAX_SPRITES} there is room for`);
}

/* Framebuffer#put_back_cell */
function put_back_cell(x, y) {
  const at = y * RG_SCREEN_WIDTH + x;
  set_pixel(x, y, scenery[at]);
  const kept = mixes_of(target);
  if (!kept || !paintable(x, y) || !scenery_mixes.is_mixed[at]) return;
  kept.is_mixed[at] = 1;
  kept.tops[at] = scenery_mixes.tops[at];
  kept.unders[at] = scenery_mixes.unders[at];
}

/* Reference#restore_patch */
function restore_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const x = left + col, y = top + row;
      if (on_screen(x, y)) put_back_cell(x, y);
    }
  }
}

function restore_turned_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    const line = turned_box_line(top, row);
    if (line >= 0) restore_patch(left, line, width, 1);
  }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over;
 * null when it is not on the picture. */
function forget_drawn_place(sprite) {
  fault_unless_sprite(sprite);
  const place = last_drawn[sprite];
  if (!place.drawn) return null;
  place.drawn = 0;
  return place;
}

/* Reference#restore_scene_rect */
function rg_object_take_off(sprite, width, height) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  restore_patch(place.x, place.y, width, height);
}

/* Ruby's Integer.sqrt */
function whole_root(value) {
  let root = Math.floor(Math.sqrt(value));
  while (root * root > value) root--;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

function rg_object_take_off_turned(sprite, image, resizes) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  const art = picture_of(image);
  const width = art.width, height = art.height;
  const middle_x = place.x + Math.trunc(width / 2), middle_y = place.y + Math.trunc(height / 2);
  if (resizes) {
    restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  const side = whole_root(width * width + height * height) + 2;
  restore_turned_patch(middle_x - Math.trunc(side / 2), middle_y - Math.trunc(side / 2), side, side);
}

function add_placed(placed) {
  fault_unless_sprite(placed.sprite);
  if (drawing.length >= RG_MAX_SPRITES) rg_fault(`more than ${RG_MAX_SPRITES} sprites on screen at once`);
  drawing.push(placed);
}

function rg_objects_add(sprite, image, x, y, level) {
  add_placed({ sprite, image, x, y, level, turned: 0, angle: 0, size: 0, resizes: 0 });
}

function rg_objects_add_turned(sprite, image, x, y, level, angle, size, resizes) {
  add_placed({ sprite, image, x, y, level, turned: 1, angle, size, resizes });
}

/* Whether the sprites a pass drew are the sprites the last rebuild painted, in the same places:
 * compared field by field as they are laid down, with nothing worked out. */
function same_sprites(drawn, kept) {
  if (drawn.length !== kept.length) return false;
  for (let i = 0; i < drawn.length; i++) {
    const a = drawn[i], b = kept[i];
    if (a.sprite !== b.sprite || a.image !== b.image || a.x !== b.x || a.y !== b.y || a.level !== b.level ||
        a.turned !== b.turned || a.angle !== b.angle || a.size !== b.size || a.resizes !== b.resizes) return false;
  }
  return true;
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
 * screen now are kept (#snapshot_object_layer) and the rebuild is owed, unless they are the
 * sprites, in the same places, that the last rebuild painted: the interpreter builds it every
 * time, and this only when something moved. */
function rg_objects_end() {
  mark_slices_left_out(drawing);
  const kept = sprite_layer;
  sprite_layer = drawing.slice();
  // Reference#show_objects_over_picture: in the layer in front of a painted picture, never into it.
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SPRITES_OVER_PICTURE]) {
    over_picture.fill(NOTHING_OVER);
    painting_over_picture = true;
    for (const placed of drawing) draw_placed(placed);
    painting_over_picture = false;
    over_picture_up = drawing.length > 0;
    return;
  }
  if (rebuilt_whole()) {
    if (!same_sprites(drawing, kept)) request_repaint();
    else skip_repaint();
    return;
  }
  // The sprite layer is off while a painted screen is up in a game with screens drawn from tiles.
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  for (const placed of drawing) {
    mix_as_sprite(placed.sprite);
    draw_placed(placed);
    mix_nothing();
    const place = last_drawn[placed.sprite];
    place.drawn = 1;
    place.x = placed.x;
    place.y = placed.y;
  }
}

/* Reference#sprites: what the game last put on screen. */
function rg_screen_drawn_count() { return drawing.length; }

function rg_screen_drawn_sprite(place) {
  const placed = drawing[place];
  return { name: rg_game_sprite_names[placed.sprite], picture: rg_game_image_pictures[placed.image], x: placed.x, y: placed.y };
}

const NO_PLACE = -1;
function place_named(said, count) {
  const place = said < 0 ? said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order */
function rg_place_in_ordered_run(said, count) {
  const place = place_named(said, count);
  if (place === NO_PLACE) rg_fault(`a draw order names sprite ${said} of the ${count} it puts in order`);
  return place;
}

/* Reference#collision_sprite */
function rg_pose_image(poses, count, pose) {
  const place = place_named(pose, count);
  if (place === NO_PLACE) rg_fault(`a sprite is showing picture ${pose} of its ${count}`);
  return poses[place];
}

/* Reference#pixels_overlap? */
function rg_pixels_overlap(a_image, a_x, a_y, b_image, b_x, b_y) {
  const a = picture_of(a_image), b = picture_of(b_image);
  const left = a_x > b_x ? a_x : b_x, top = a_y > b_y ? a_y : b_y;
  const a_right = a_x + a.width, b_right = b_x + b.width;
  const a_bottom = a_y + a.height, b_bottom = b_y + b.height;
  const right = a_right < b_right ? a_right : b_right, bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (let y = top; y < bottom; y++) {
    for (let x = left; x < right; x++) {
      if (a.pixels[a.start + (y - a_y) * a.width + (x - a_x)] !== RG_NOT_DRAWN &&
          b.pixels[b.start + (y - b_y) * b.width + (x - b_x)] !== RG_NOT_DRAWN) return 1;
    }
  }
  return 0;
}

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

function fade_unless_left_as_drawn(fade_place) {
  const under = placed_fade.layer_place;
  const left_as_drawn = under !== RG_NO_LAYER && fade_place !== RG_NO_LAYER && fade_place >= under;
  fading_what_is_painted = placed_fade.in_force && !left_as_drawn ? 1 : 0;
}

function fade_nothing() { fading_what_is_painted = 0; }

/* Back to front: the backdrop, then each level's scenery (rg_hook_paint_level) and its sprites,
 * with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending). */
function repaint_view() {
  repaints_painted++;
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(backdrop);
  rg_hook_repaint_began();
  const levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (let level = 0; level < levels; level++) {
    rg_hook_paint_level(level);
    for (const placed of sprite_layer) {
      if (placed.level !== level) continue;
      mix_as_sprite(placed.sprite);
      fade_unless_left_as_drawn(rg_game_sprite_fade_places[placed.sprite]);
      paint_kept_sprite(placed);
    }
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
    // What was under each sprite went with the old screen, so nothing is put back over the new
    // one. A console that places its sprites at the end of a pass takes them off after this.
    for (const place of last_drawn) place.drawn = 0;
    over_picture_up = false;
  } else {
    show_backdrop(new_backdrop);
  }
  kind = new_kind;
  show_pages(two_pages);
  tint_by_display = tint_mixed_by_display();
  rg_hook_screen_set();
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
  if (painted_screen() || sprite_layer.length === 0) return;
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

/* --- a light (Framebuffer#shade_outside) --- */

const shade_spans = new Int32Array(RG_SCREEN_HEIGHT * 2);
let shade_steps = 0;
let shade_row = 0;

function rg_shade_line() { return shade_row; }
function rg_shade_left(left) { shade_spans[shade_row * 2] = left; }
function rg_shade_right(right) { shade_spans[shade_row * 2 + 1] = right; }
function rg_shade_darkness(amount) { shade_steps = whole_sixteenths(amount); }

/* Reference#work_out_shade */
function rg_screen_work_out_shade() {
  for (shade_row = 0; shade_row < RG_SCREEN_HEIGHT; shade_row++) rg_game_shade_span();
  rg_game_shade_amount();
}

/* Framebuffer#light_off= (rg_screen.c) */
let shade_off = false;
function rg_shade_switch(on) { shade_off = on === 0; }

/* Framebuffer#lit? */
function lit(x, y) {
  if (shade_steps === 0 || shade_off) return true;
  const left = shade_spans[y * 2], right = shade_spans[y * 2 + 1];
  return left <= right ? x >= left && x < right : x >= left || x < right;
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

/* Framebuffer#shown and #pixel: each pixel read from where a feature says it is read from
 * (rg_hook_shown_columns, rg_hook_shown_row), or its own place. */
function rg_screen_shown() {
  rg_screen_paint_owed_rebuild();
  const columns = rg_hook_shown_columns();
  for (let y = 0; y < RG_SCREEN_HEIGHT; y++) {
    const from_y = rg_hook_shown_row(y) + camera_y;
    for (let x = 0; x < RG_SCREEN_WIDTH; x++) {
      const fade_here = fade_reaches(x, y);
      const over = over_picture_up ? over_picture[y * RG_SCREEN_WIDTH + x] : NOTHING_OVER;
      let color;
      if (over !== NOTHING_OVER) {
        color = faded_where(over, fade_here); // a sprite over the picture is not in blocks
      } else {
        const from_x = (columns ? columns[x] : x) + camera_x;
        const at = from_y * RG_SCREEN_WIDTH + from_x;
        color = on_screen(from_x, from_y) ? shown_color(at, viewed[at], fade_here) : faded_where(0, fade_here);
      }
      shown[y * RG_SCREEN_WIDTH + x] = held ? 0x7FFF : lit(x, y) ? color : darkened_by_display(color, shade_steps);
    }
  }
  keep_console_colors();
  return shown;
}
