# THE GAME'S PICTURE, drawn in software: the console's screen as an array of colors, and
# everything the game does to it — drawing, backgrounds, sprites, the window over the picture,
# fades and tints, a picture in blocks, see-through layers, bends and the light.
#
# Each method names which of the interpreter's it answers for (in backends/reference.rb and
# reference/framebuffer.rb), because the interpreter is what this is checked against pixel for
# pixel. That includes the parts that look like bookkeeping — when the whole view is rebuilt,
# which scenery is up, what a scene takes down as it arrives — since each decides what a pixel
# holds on some frame.
#
# A color is the console's: fifteen bits, five each of red, green and blue, red lowest, kept as
# a whole number. A sprite's picture is kept as signed sixteen-bit numbers, RG_NOT_DRAWN (-1)
# where what is behind shows, and a background's tiles as unsigned ones, RG_SEE_THROUGH (0xFFFF)
# there; a color painted is held to sixteen bits (& 0xFFFF) as it goes in.
#
# A sprite's pictures and a background's tiles arrive ready to draw, in the game's tables
# (@rg_game_images, @rg_game_tile_pixels and the rest): which pixels show, and the colors of each
# list they can be drawn with, were worked out when the game was built.
#
# The screen's size is the console's the game is built for: RG_SCREEN_WIDTH and RG_SCREEN_HEIGHT
# come first in the game's class, written by the lowering (Lowering#console_text).

RG_SCREEN_CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT
RG_SWITCHED_OFF = 0x7FFF # What a switched-off display shows: plain white

# The kinds of screen a `screen` can name.
RG_BITMAP = 0
RG_TILED = 1
RG_ROTOZOOM = 2

RG_FADE_WHOLE_SCREEN = 0
RG_FADE_INSIDE = 1
RG_FADE_OUTSIDE = 2

RG_NOT_DRAWN = -1      # A sprite picture's pixel where what is behind shows
RG_SEE_THROUGH = 0xFFFF # A tile's pixel where the layer behind shows

# Backends::FadeSteps: a walk of the colors counts in 256ths, sixteen to a display's step.
RG_WALK_STEPS = 256
RG_WALK_PER_DISPLAY = 16
RG_SOLID = -1          # A thing in no see-through layer
RG_NO_NAME = -1
RG_NOT_IN_BLOCKS = -1
RG_NO_LAYER = -1
RG_MAX_SPRITES = 512
RG_MAX_SEE_THROUGH = 16
RG_AREAS_DEEP = 64
RG_IMAGE_FIELDS = 3

# Each layer the game can be seen through is RG_ST_FIELDS numbers in @rg_game_see_through.
RG_ST_AMOUNTS_WRITTEN = 0
RG_ST_ONE_AMOUNT = 1
RG_ST_HOLDS_A_SPRITE = 2
RG_ST_FIELDS = 3

# Each run of tiles the game paints from a list is RG_RUN_FIELDS numbers in @rg_game_tile_runs.
RG_RUN_TILES = 0
RG_RUN_WIDTH = 1
RG_RUN_HEIGHT = 2
RG_RUN_PLACES = 3
RG_RUN_FIRST_IMAGE = 4
RG_RUN_IMAGES = 5
RG_RUN_PLANES = 6
RG_RUN_FIELDS = 7
RG_RUN_IMAGE_FIELDS = 17
RG_RUN_TILE_SIDE = 8
RG_RUN_TILE_PIXELS = RG_RUN_TILE_SIDE * RG_RUN_TILE_SIDE
RG_PLACES_IN_RUN_COLORS = 16

# The places in @rg_game_picture_sizes.
RG_SIZE_BACKGROUNDS = 0
RG_SIZE_DEPTHS = 1
RG_SIZE_ALWAYS_UP = 2
RG_SIZE_REBUILT_WHOLE = 3
RG_SIZE_SEE_THROUGH = 4
RG_SIZE_SCREEN_KINDS_CHANGE = 5
RG_SIZE_LARGEST_BLOCK = 6
RG_SIZE_RUNS = 7
RG_SIZE_RUN_PIXELS = 8
RG_SIZE_IMAGES = 9
RG_SIZE_SPRITES_OVER_PICTURE = 10

RG_NOBODY_ASKED = -1
RG_NO_CELL = -1        # A cell of a saved patch that hung off the picture

# The part of the screen drawing is held inside (Framebuffer#draw_inside), when it is held.
RgArea = Struct.new(:in_force, :left, :top, :right, :bottom)

# The two colors each mixed cell was mixed from (Framebuffer @mixed_tops), for a tint that moves
# the color table, which reaches each side before the mix (see rg_shown_color). +is_mixed+ is
# nought for a cell painted solid. Kept for the picture, and for the scenery kept apart to put
# back behind a sprite, so a cell put back is still a mix.
class RgMixes
  attr_reader :is_mixed, :tops, :unders

  def initialize
    @is_mixed = Array.new(RG_SCREEN_CELLS, 0)
    @tops = Array.new(RG_SCREEN_CELLS, 0)
    @unders = Array.new(RG_SCREEN_CELLS, 0)
  end
end

# A FADE PLACED IN THE STACK (Reference @fade_placed): whether one is in force, how far forward the
# layer it sits under is among the layers the game declared, which way it fades, and how far.
RgPlacedFade = Struct.new(:in_force, :layer_place, :toward_white, :steps)

def rg_screen_setup
  # TWO PAGES, OR ONE (Framebuffer#paged=). A tear-free screen is two pictures: the display shows
  # one while the game draws into the other, and they trade places between frames, so nobody ever
  # sees a half-drawn picture. Drawing always lands on @rg_pixels and the viewer always reads
  # @rg_viewed; with one page those are the same picture. Which page is which is told by identity
  # (equal?), never by what they hold.
  @rg_first_page = Array.new(RG_SCREEN_CELLS, 0)
  @rg_second_page = Array.new(RG_SCREEN_CELLS, 0)
  @rg_backdrop = 0 # the colour shown wherever nothing is drawn (Reference @backdrop)
  @rg_pixels = @rg_first_page
  @rg_viewed = @rg_first_page
  @rg_shown = Array.new(RG_SCREEN_CELLS, 0)
  # Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back under
  # a sprite (Reference#drawing_into).
  @rg_target = @rg_first_page
  @rg_area = RgArea.new(false, 0, 0, 0, 0)
  @rg_outer_areas = []
  # Where the window onto the picture sits (Framebuffer#camera_to): screen (0, 0) shows what was
  # drawn at (camera_x, camera_y). Nothing drawn moves.
  @rg_camera_x = 0
  @rg_camera_y = 0
  # The patches of picture saved under bitmap sprites, by buffer number (Reference @backing).
  @rg_saved_patches = []
  # THE SCENERY WITH NOTHING ON IT (Reference @scene_fb): the backdrop and every background up,
  # painted once and kept, to put back under a sprite drawn straight onto a picture that is not
  # rebuilt every frame.
  @rg_scenery = Array.new(RG_SCREEN_CELLS, 0)
  @rg_scenery_kept = false
  @rg_screen_held = 0 # switched off until the first frame (Framebuffer#held=)
  @rg_frames_begun = false # a frame boundary has been reached (Reference @uses_frames)
  @rg_placing_at_pass_end = false # the end of a pass is placing the frame's writes (Reference @placing_at_pass_end)
  @rg_kind = -1 # the kind of screen up; none before the first `screen`
  @rg_rebuild_pending = false # a rebuild of the whole view is owed (Reference#request_repaint)
  @rg_repaints_painted = 0 # how many times the whole view was built again (rg_screen_repaints_painted)
  # The interpreter asks for a rebuild every time the scroll or the sprites are set. Here a setting
  # that moved nothing asks for nothing and only notes that it would have (@rg_rebuild_skipped),
  # since the picture is the one a rebuild would paint. That stops being so once the picture is
  # touched: something else has written to it, or the pages have changed over. So when the rebuild
  # would be painted, a skipped one with the picture touched is painted after all, whichever came
  # first.
  @rg_rebuild_skipped = false
  @rg_picture_touched = false
  @rg_scene = -1
  # What a display does to the finished picture: one effect at a time (Framebuffer#fade_to).
  @rg_fade_white = 0
  @rg_fade_steps = 0
  @rg_tint_mode = :none # :none, :toward or :color
  @rg_tint_white = 0
  @rg_tint_color = 0
  @rg_tint_steps = 0
  @rg_tint_by_display = false
  @rg_placed_fade = RgPlacedFade.new(false, RG_NO_LAYER, 0, 0)
  @rg_fading_what_is_painted = false # Framebuffer @paint_toward
  # WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through):
  # [sixteenths of what is painted, sixteenths of what is under it].
  @rg_mixing = false
  @rg_mixed_by = [16, 0]
  @rg_picture_mixes = RgMixes.new
  @rg_scenery_mixes = RgMixes.new
  @rg_mixed_cells_by = [16, 0]
  # THE PICTURE WITH NO SPRITES ON IT (Framebuffer @scenery), in a game with a sprite in a
  # see-through layer: a see-through sprite is mixed with this and never with a sprite behind it.
  @rg_picture_without_sprites = Array.new(RG_SCREEN_CELLS, 0)
  @rg_painting_sprite = false
  @rg_seen_through_answer = nil
  # A layer a feature paints into as it is (rg_paint_onto_plain_layer), or nil while drawing goes to
  # the picture, so a pixel painted then costs one test and no method call.
  @rg_plain_layer = nil
  # See-through layers: the one being asked about and its answer, and its shares as kept when a
  # rebuild was asked for (Reference @owed_weights) and as last told (@see_through_shown).
  @rg_asked_layer = RG_NOBODY_ASKED
  @rg_answered = [0, 0]
  @rg_pending_shares = Array.new(RG_MAX_SEE_THROUGH)
  @rg_told_shares = Array.new(RG_MAX_SEE_THROUGH)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  @rg_fade_area = [0, 0, 0, 0]
  # WHAT THE GAME HAS PAINTED (Reference @bitmaps, for a run's tiles and pictures): every run's
  # pixels as places in its colors, place 0 see-through; and the images painted from them.
  @rg_painted_places = nil
  @rg_painted_images = nil
  # A light: each row's lit span, how many sixteenths the rest is darkened by, the row being asked
  # about, and whether the scene that just ran has it off.
  @rg_shade_spans = Array.new(RG_SCREEN_HEIGHT) { [0, 0] }
  @rg_shade_steps = 0
  @rg_shade_row = 0
  @rg_shade_off = false
  rg_hook_setup # the state of the game's runtime features (RuntimeFeatures)
end

# --- small arithmetic ---

# The game's numbers are whole; Ruby's / and % already round down, which is what the picture's
# arithmetic wants wherever a number can be below nought.
def rg_clamp_wide(value, low, high) = value < low ? low : (value > high ? high : value)

# --- the picture itself (Framebuffer) ---

def rg_on_screen?(x, y) = x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT

# Framebuffer#paintable?: on the screen, and inside the area drawing is held to when it is.
def rg_paintable?(x, y)
  return false unless rg_on_screen?(x, y)

  area = @rg_area
  !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom)
end

# Framebuffer#mix_see_through: a see-through layer's color over what is under it. Each channel is
# widened to eight bits first, its share of each side added and only then the sixteenth dropped,
# and the answer taken back to five bits. Past a whole, a channel stops at its brightest.
#
# The three channels are written out rather than looped over: this runs for every pixel of a
# see-through layer, and a loop over them costs a block call each and a shift worked out each
# time, on top of the sums.
#
# A channel is WIDENED from five bits to eight by repeating its top bits underneath ((c << 3) |
# (c >> 2), Framebuffer#widen_channel), so the brightest five-bit value, 31, becomes the brightest
# eight-bit one, 255, rather than 248; every channel helper here widens that way.
def rg_mixed_with_under(color, under, by)
  top = by[0]
  bottom = by[1]
  red = rg_mixed_channel_with_under(color & 0x1F, under & 0x1F, top, bottom)
  green = rg_mixed_channel_with_under((color >> 5) & 0x1F, (under >> 5) & 0x1F, top, bottom)
  blue = rg_mixed_channel_with_under((color >> 10) & 0x1F, (under >> 10) & 0x1F, top, bottom)
  red | (green << 5) | (blue << 10)
end

# One channel of rg_mixed_with_under, five bits in and five out.
def rg_mixed_channel_with_under(have, below, top, bottom)
  mix = ((((have << 3) | (have >> 2)) * top) + (((below << 3) | (below >> 2)) * bottom)) / 16
  (mix > 255 ? 255 : mix) >> 3
end

# Framebuffer#darkened_by_display: each channel widened to eight bits and placed in its own byte,
# taken +steps+ sixteenths of the way to black there, and brought back to five bits. Done in the
# channel's own byte as the interpreter does it, which rounds how much the first channel loses
# down and how much the other two lose up.
#
# The channels are written out rather than looped over, as in rg_mixed_with_under.
def rg_darkened_by_display(color, steps)
  return color if steps == 0

  red = rg_darkened_channel(color & 0x1F, 0, steps)
  green = rg_darkened_channel((color >> 5) & 0x1F, 8, steps)
  blue = rg_darkened_channel((color >> 10) & 0x1F, 16, steps)
  (red | (green << 5) | (blue << 10)) & 0xFFFF
end

# One channel of rg_darkened_by_display, placed +byte_shift+ bits up while it is darkened.
def rg_darkened_channel(channel, byte_shift, steps)
  placed = ((channel << 3) | (channel >> 2)) << byte_shift
  ((placed - ((placed * steps) / 16)) >> byte_shift) >> 3
end

# Framebuffer#brightened_by_display: each channel widened to eight bits and given +steps+
# sixteenths of the headroom it has left there, then brought back to five bits.
def rg_brightened_by_display(color, steps)
  return color if steps == 0

  rg_brightened_channel(color & 0x1F, steps) | (rg_brightened_channel((color >> 5) & 0x1F, steps) << 5) |
    (rg_brightened_channel((color >> 10) & 0x1F, steps) << 10)
end

# One channel of rg_brightened_by_display, five bits in and five out.
def rg_brightened_channel(channel, steps)
  have = (channel << 3) | (channel >> 2)
  (have + (((255 - have) * steps) / 16)) >> 3
end

# Framebuffer#faded_by_display: the display's own fade toward black or white.
def rg_faded_by_display(color, white, steps)
  white != 0 ? rg_brightened_by_display(color, steps) : rg_darkened_by_display(color, steps)
end

# Framebuffer#apply_placed_fade: a color as it is painted while a placed fade reaches it.
def rg_faded_as_painted(color)
  color &= 0xFFFF
  return color unless @rg_fading_what_is_painted

  rg_faded_by_display(color, @rg_placed_fade.toward_white, @rg_placed_fade.steps)
end

# The mixed sides kept for +page+: the picture being drawn into, or the scenery kept apart; nil
# for any other page, which is never shown with a tint and never put back.
def rg_mixes_of(page)
  return @rg_picture_mixes if page.equal?(@rg_pixels)

  page.equal?(@rg_scenery) ? @rg_scenery_mixes : nil
end

# Framebuffer#blend_into_cell: a color on its way into the cell at +at+ of +page+, which holds
# +under+. The fade a placed fade asks for first, then the mix a see-through layer asks for. The
# cell keeps the two colors of its mix, or stops being a mix when painted solid.
def rg_into_cell(color, under, page, at)
  painted = rg_faded_as_painted(color)
  kept = rg_mixes_of(page)
  if kept
    kept.is_mixed[at] = @rg_mixing ? 1 : 0
    if @rg_mixing
      kept.tops[at] = painted
      kept.unders[at] = under
    end
  end
  @rg_mixing ? rg_mixed_with_under(painted, under, @rg_mixed_by) : painted
end

# Reference#see_through_sprites?: is any sprite in a see-through layer? The game's, and it never
# changes, so it is worked out once.
def rg_sprites_seen_through?
  return @rg_seen_through_answer unless @rg_seen_through_answer.nil?

  @rg_seen_through_answer = Array.new(@rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]) do |layer|
    @rg_game_see_through[(layer * RG_ST_FIELDS) + RG_ST_HOLDS_A_SPRITE]
  end.any? { |holds| holds != 0 }
end

# Whether the picture with no sprites on it is kept beside what is being drawn into
# (Framebuffer#keep_scenery). The copy of the scenery kept to put back under sprites keeps none.
def rg_keeps_picture_without_sprites? = !@rg_target.equal?(@rg_scenery) && rg_sprites_seen_through?

# Framebuffer#set_pixel: a cell drawing may not land on is dropped. A sprite is mixed with the
# picture as it is with no sprite on it, where that is kept, and anything else with what is
# already in the cell.
#
# While a feature has handed over a plain layer, the pixel is stored whole there and nowhere else.
def rg_set_pixel(x, y, color)
  if (layer = @rg_plain_layer)
    layer[(y * RG_SCREEN_WIDTH) + x] = color if rg_on_screen?(x, y)
    return
  end
  return unless rg_paintable?(x, y)

  @rg_picture_touched = true
  at = (y * RG_SCREEN_WIDTH) + x
  kept = rg_keeps_picture_without_sprites?
  under = kept && @rg_painting_sprite ? @rg_picture_without_sprites : @rg_target
  painted = rg_into_cell(color, under[at], @rg_target, at)
  @rg_target[at] = painted
  @rg_picture_without_sprites[at] = painted if kept && !@rg_painting_sprite
end

# A layer a feature paints into as it is, a colour or nil for each of the screen's cells, until it
# hands it back with nil: each painted pixel is stored whole there, with no area, mix or fade.
def rg_paint_onto_plain_layer(layer)
  @rg_plain_layer = layer
end

# PAINTING PLAIN. What rg_set_pixel asks of every pixel — a plain layer handed over, a see-through
# mix, a placed fade, the picture without sprites kept beside — is the same for every pixel of one
# blit or fill, and for nearly every one of them the answer is "none". When it is, the whole shape
# is painted here a row at a time: the part of it inside the screen and the area worked out once,
# and each pixel only stored, its cell marked as no mix where the picture keeps mixes. It paints
# exactly the cells rg_set_pixel would, the same colours. Anything else goes through rg_set_pixel.
#
# This is the Ruby runtime's own: YJIT compiles each small method of rg_set_pixel's to a call of
# its own, and a blit makes several of them for every pixel.
def rg_painting_plain? = !@rg_plain_layer && !@rg_mixing && !@rg_fading_what_is_painted && !rg_keeps_picture_without_sprites?

# The columns or rows a shape from +start+ to +past+ keeps inside the screen's +side+ and the area's
# +low+ and +high+ (when it is in force): the first, and the one after the last.
def rg_kept_span(start, past, side, low, high, in_force)
  first = start < 0 ? 0 : start
  last = past > side ? side : past
  if in_force
    first = low if first < low
    last = high if last > high
  end
  [first, last]
end

# Framebuffer#fill_rect: every cell of the rectangle, each through rg_set_pixel. Walking only the
# part on the screen paints the same cells.
def rg_fill_cells(x, y, width, height, color)
  return rg_fill_cells_plain(x, y, width, height, color & 0xFFFF) if rg_painting_plain?

  left = x < 0 ? 0 : x
  top = y < 0 ? 0 : y
  right = x + width
  bottom = y + height
  right = RG_SCREEN_WIDTH if right > RG_SCREEN_WIDTH
  bottom = RG_SCREEN_HEIGHT if bottom > RG_SCREEN_HEIGHT
  py = top
  while py < bottom
    px = left
    while px < right
      rg_set_pixel(px, py, color)
      px += 1
    end
    py += 1
  end
end

# rg_fill_cells when painting plain (rg_painting_plain?): +color+ already the sixteen bits a cell holds.
def rg_fill_cells_plain(x, y, width, height, color)
  area = @rg_area
  left, right = rg_kept_span(x, x + width, RG_SCREEN_WIDTH, area.left, area.right, area.in_force)
  top, bottom = rg_kept_span(y, y + height, RG_SCREEN_HEIGHT, area.top, area.bottom, area.in_force)
  return if left >= right || top >= bottom

  @rg_picture_touched = true
  target = @rg_target
  mixes = rg_mixes_of(target)
  is_mixed = mixes&.is_mixed
  count = right - left
  py = top
  while py < bottom
    at = (py * RG_SCREEN_WIDTH) + left
    target.fill(color, at, count)
    is_mixed&.fill(0, at, count)
    py += 1
  end
end

# Framebuffer#clear: the whole picture, or the area drawing is held to and no more.
def rg_clear_to(color)
  area = @rg_area
  return rg_fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color) if area.in_force

  @rg_picture_touched = true
  painted = rg_faded_as_painted(color)
  @rg_target.fill(painted)
  kept = rg_mixes_of(@rg_target)
  kept&.is_mixed&.fill(0)
  return unless rg_keeps_picture_without_sprites?

  @rg_picture_without_sprites.fill(painted)
end

def rg_screen_clear(color) = rg_clear_to(color)
def rg_screen_fill_rect(x, y, width, height, color) = rg_fill_cells(x, y, width, height, color)

# Reference#exec_inside: the area before is kept, to be given back by rg_screen_inside_ended.
def rg_screen_inside(x, y, width, height)
  rg_fault("more than #{RG_AREAS_DEEP} `inside` blocks are open at once") if @rg_outer_areas.length >= RG_AREAS_DEEP
  @rg_outer_areas.push(@rg_area)
  @rg_area = RgArea.new(true, x, y, x + width, y + height)
end

# A frame may end between the two. The picture is read whole whatever area is open, and nothing
# is painted after a run stops.
def rg_screen_inside_ended
  @rg_area = @rg_outer_areas.pop
end

# Reference#exec_camera
def rg_screen_camera(x, y)
  @rg_camera_x = x
  @rg_camera_y = y
end

def rg_screen_camera_x = @rg_camera_x
def rg_screen_camera_y = @rg_camera_y

# Framebuffer#paged=. Going to two pages, the one drawn so far goes on being drawn into and a blank
# one is shown, which is what the console does on the way in. Going back to one, the two are the
# page holding the drawing.
def rg_show_pages(two)
  return if (two != 0) == !@rg_pixels.equal?(@rg_viewed)

  if two == 0
    @rg_viewed = @rg_pixels
    return
  end
  @rg_viewed = @rg_pixels.equal?(@rg_first_page) ? @rg_second_page : @rg_first_page
  @rg_viewed.fill(0)
end

# Reference#exec_save_region: the patch of the picture at (x, y), as it is stored — what is
# really in the picture, wherever the window sits, and whatever area drawing is held to. A cell off
# the screen is remembered as nothing.
def rg_patch_save(buffer, width, height, x, y)
  patch = @rg_saved_patches[buffer] ||= Array.new(width * height, RG_NO_CELL)
  height.times do |row|
    width.times do |col|
      px = x + col
      py = y + row
      patch[(row * width) + col] = rg_on_screen?(px, py) ? @rg_pixels[(py * RG_SCREEN_WIDTH) + px] : RG_NO_CELL
    end
  end
end

# Reference#exec_restore_region: a patch never saved puts nothing back, and neither does a cell
# remembered as nothing.
def rg_patch_restore(buffer, width, height, x, y)
  patch = @rg_saved_patches[buffer] or return

  height.times do |row|
    width.times do |col|
      color = patch[(row * width) + col]
      rg_set_pixel(x + col, y + row, color) if color != RG_NO_CELL
    end
  end
end

def rg_screen_pixel(x, y, color) = rg_set_pixel(x, y, color)

# Two colors for a line of text, and the test that picks which.
def rg_pick_color(showing, color, picked) = showing != 0 ? picked : color

# Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. The points
# are (dx, dy) pairs in +points+, +count+ of them from pair +from+ on.
def rg_screen_points(x, y, color, points, count, from = 0)
  count.times do |i|
    at = 2 * (from + i)
    rg_set_pixel(x + points[at], y + points[at + 1], color)
  end
end

# Reference#exec_draw_digit: +starts+ holds where each of the ten digits' points begin.
def rg_screen_digit(value, x, y, color, points, starts)
  return if value < 0 || value > 9

  rg_screen_points(x, y, color, points, starts[value + 1] - starts[value], starts[value])
end

# --- see-through layers ---

def rg_see_through_layers = @rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]
def rg_see_through_field(layer, field) = @rg_game_see_through[(layer * RG_ST_FIELDS) + field]

def rg_see_through_asked(layer) = layer == @rg_asked_layer ? 1 : 0

def rg_see_through_answer(shows, behind)
  @rg_answered = [shows, behind]
end

# IR::SeeThrough.nearest_steps and .floor_steps: an amount out of 100 as sixteenths.
def rg_nearest_sixteenths(amount) = rg_clamp_wide(((amount * 16) + 50) / 100, 0, 16)
def rg_whole_sixteenths(amount) = rg_clamp_wide((amount * 16) / 100, 0, 16)

# Reference#live_see_through_weights, through IR::SeeThrough.weights: a layer's two shares from
# its amounts as the game works them out now. Given one amount, what is behind takes its share
# rounded down and the layer whatever is left of a whole; given two, each is taken to the nearest
# sixteenth.
def rg_shares_now(layer)
  @rg_asked_layer = layer
  rg_game_see_through_amounts
  @rg_asked_layer = RG_NOBODY_ASKED
  shows, behind = @rg_answered
  if rg_see_through_field(layer, RG_ST_ONE_AMOUNT) != 0
    under = rg_whole_sixteenths(behind)
    return [16 - under, under]
  end
  [rg_nearest_sixteenths(shows), rg_nearest_sixteenths(behind)]
end

# Reference#layer_has_anything?: scenery showing now (rg_hook_layer_holds_scenery), or a sprite
# anywhere, since whether a sprite is shown is a variable too.
def rg_layer_holds_anything?(layer)
  rg_see_through_field(layer, RG_ST_HOLDS_A_SPRITE) != 0 || rg_hook_layer_holds_scenery(layer)
end

# Reference#capture_see_through_weights. A rebuild is painted later than it is asked for, and the
# game's variables can move in between, so the amounts a game works out are read when the rebuild
# is asked for and the painting uses those. Only for a layer with something in it that could be on
# screen: nothing is worked out that painting would not have worked out.
def rg_keep_shares_for_pending_rebuild
  rg_see_through_layers.times do |layer|
    keep = rg_see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) == 0 && rg_layer_holds_anything?(layer)
    @rg_pending_shares[layer] = keep ? rg_shares_now(layer) : nil
  end
end

def rg_forget_kept_shares
  rg_see_through_layers.times { |layer| @rg_pending_shares[layer] = nil }
end

# Reference#fading?: is a fade in force that takes the display's blend? While such a fade runs a
# see-through layer is solid. A fade that walks the colors sets no fade amount and is never found
# here, and the copy of the scenery kept to put back under sprites never has one. A fade placed in
# the stack is the game's and takes the blend whichever is being painted.
def rg_fade_holds_blend?
  return @rg_placed_fade.steps > 0 if @rg_placed_fade.in_force

  !@rg_target.equal?(@rg_scenery) && @rg_fade_steps > 0
end

# Reference#set_see_through_for, for scenery: mixing on for a thing in a see-through layer, off for
# anything else. +layer+ is RG_SOLID for a thing in none.
def rg_mix_as_layer(layer)
  @rg_painting_sprite = false
  @rg_mixing = layer != RG_SOLID && !rg_fade_holds_blend?
  return unless @rg_mixing

  @rg_mixed_by = @rg_mixed_cells_by = @rg_pending_shares[layer] || rg_shares_now(layer)
end

def rg_mix_nothing
  @rg_mixing = false
  @rg_painting_sprite = false
end

# --- effects over the finished picture (Framebuffer#faded) ---

# Framebuffer#walked_toward: a fade that walks the colors, in five bits a channel, each channel
# moved a truncated share of the way to black or white.
def rg_walked_toward(color, white, steps)
  return color if steps == 0

  # FadeSteps.dimmed_levels, on a display that dims
  level = steps >= RG_WALK_STEPS ? 0 : 15 - ((steps * 15) / RG_WALK_STEPS)
  out = 0
  3.times do |channel|
    c = (color >> (5 * channel)) & 0x1F
    c = if RG_CONSOLE_DIMS && white == 0 then ((2 * c * level) + 15) / 30
        else white != 0 ? c + (((31 - c) * steps) / RG_WALK_STEPS) : c - ((c * steps) / RG_WALK_STEPS)
        end
    out |= c << (5 * channel)
  end
  out
end

# Framebuffer#mixed and #mixed_by_display: the two shares added, and only then the fraction
# dropped. The display mixes at eight bits a channel; a game writing tinted colors, at five.
#
# The channels are written out rather than looped over, as in rg_mixed_with_under.
def rg_mixed(color, toward, steps, by_display)
  return color if steps == 0

  keep = RG_WALK_STEPS - steps
  red = rg_mixed_channel(color & 0x1F, toward & 0x1F, keep, steps, by_display)
  green = rg_mixed_channel((color >> 5) & 0x1F, (toward >> 5) & 0x1F, keep, steps, by_display)
  blue = rg_mixed_channel((color >> 10) & 0x1F, (toward >> 10) & 0x1F, keep, steps, by_display)
  red | (green << 5) | (blue << 10)
end

# One channel of rg_mixed, five bits in and five out.
def rg_mixed_channel(have, want, keep, steps, by_display)
  return ((have * keep) + (want * steps)) / RG_WALK_STEPS unless by_display

  (((((have << 3) | (have >> 2)) * keep) + (((want << 3) | (want >> 2)) * steps)) / RG_WALK_STEPS) >> 3
end

# Framebuffer#faded. +fade_here+ is false where a fade held to a rectangle does not reach.
def rg_faded_where(color, fade_here)
  case @rg_tint_mode
  when :toward
    # On the plain bitmap screen the display does a walked fade, in sixteenths.
    return rg_faded_by_display(color, @rg_tint_white, @rg_tint_steps / RG_WALK_PER_DISPLAY) if @rg_tint_by_display

    return rg_walked_toward(color, @rg_tint_white, @rg_tint_steps)
  when :color
    # The display counts in sixteenths, every sixteenth 256th, so the steps between are dropped.
    steps = @rg_tint_by_display ? @rg_tint_steps - (@rg_tint_steps % RG_WALK_PER_DISPLAY) : @rg_tint_steps
    return rg_mixed(color, @rg_tint_color, steps, @rg_tint_by_display)
  end
  return color unless fade_here

  rg_faded_by_display(color, @rg_fade_white, @rg_fade_steps)
end

def rg_faded(color) = rg_faded_where(color, true)

# Framebuffer#shown_color: the stored cell at +at+ with the fade or tint in force. A cell a
# see-through layer was mixed into, under a tint, is mixed again from its two colors tinted: a tint
# on a screen drawn through a color table moves the colors the display then mixes.
def rg_shown_color(at, stored, fade_here)
  if @rg_tint_mode == :none || !@rg_pixels.equal?(@rg_viewed) || @rg_picture_mixes.is_mixed[at] == 0
    return rg_faded_where(stored, fade_here)
  end

  rg_mixed_with_under(rg_faded(@rg_picture_mixes.tops[at]), rg_faded(@rg_picture_mixes.unders[at]), @rg_mixed_cells_by)
end

# Framebuffer#fade_reaches?: does the display's fade reach the screen pixel (x, y)?
def rg_fade_reaches?(x, y)
  return true if @rg_fade_side == RG_FADE_WHOLE_SCREEN

  left, top, right, bottom = @rg_fade_area
  within = x >= left && x < right && y >= top && y < bottom
  @rg_fade_side == RG_FADE_INSIDE ? within : !within
end

# Reference#exec_fade, through Framebuffer#fade_steps_to or, for a fade that walks the colors,
# #tint_steps_to. +placed+ is true for a fade placed in the stack under the layer at +layer_place+.
#
# Over the whole screen it is laid over the picture as the screen is read, so nothing drawn
# changes. Placed in the stack it is painted into the picture, so the picture is built again right
# here, and again by the fade that takes a placed one's place, which has to take it back out. A
# fade that takes the display's blend takes it from a see-through layer and hands it back as it
# lifts, so the picture is built again at each of those two moments as well.
def rg_fade_to(placed, layer_place, toward_white, steps, walked)
  took_the_blend = rg_fade_holds_blend?
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade = RgPlacedFade.new(placed, layer_place, toward_white, steps)
  if walked != 0
    @rg_tint_mode = :toward
    @rg_tint_white = toward_white
    @rg_tint_steps = steps
    @rg_tint_by_display = rg_tint_mixed_by_display? # Reference#fade_by_tint
    @rg_fade_steps = 0
  else
    @rg_fade_white = toward_white
    @rg_fade_steps = placed ? 0 : steps
    @rg_tint_mode = :none
  end
  blend_changed_hands = rg_see_through_layers > 0 && rg_fade_holds_blend? != took_the_blend
  rg_request_repaint if was_placed || placed || blend_changed_hands
end

def rg_screen_fade(toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, walked)
end

def rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps)
  @rg_fade_side = reaches
  @rg_fade_area = [left, top, right, bottom]
  rg_fade_to(false, RG_NO_LAYER, toward_white, steps, 0)
end

def rg_screen_fade_under(layer_place, toward_white, steps, walked)
  @rg_fade_side = RG_FADE_WHOLE_SCREEN
  rg_fade_to(true, layer_place, toward_white, steps, walked)
end

# Reference#tint_by_display?: does the display mix a tint in as it draws, which only the plain
# bitmap screen does, on a console that blends? Every other screen has it mixed into a colour table.
def rg_tint_mixed_by_display? = rg_painted_screen? && @rg_pixels.equal?(@rg_viewed) && RG_CONSOLE_BLENDS

# Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever fade
# was in force, one placed in the stack included, and the picture is built again when a fade that
# held a see-through layer solid, or was painted into the picture, goes.
def rg_screen_tint(color, steps)
  took_the_blend = rg_fade_holds_blend?
  was_placed = @rg_placed_fade.in_force
  @rg_placed_fade.in_force = false
  @rg_tint_mode = :color
  @rg_tint_color = color
  @rg_tint_steps = steps
  @rg_tint_by_display = rg_tint_mixed_by_display?
  @rg_fade_steps = 0
  blend_changed_hands = rg_see_through_layers > 0 && rg_fade_holds_blend? != took_the_blend
  rg_request_repaint if was_placed || blend_changed_hands
end

# Backends::FadeSteps.steps
def rg_fade_steps(amount, fraction_bits, walked)
  levels = walked != 0 ? RG_WALK_STEPS : 16
  if fraction_bits < 0
    sixteenths = rg_whole_sixteenths(amount)
    return walked != 0 ? sixteenths * RG_WALK_PER_DISPLAY : sixteenths
  end
  rg_clamp_wide((amount * levels) / (100 << fraction_bits), 0, levels)
end

def rg_run_field(run, field) = @rg_game_tile_runs[(RG_RUN_FIELDS * run) + field]

# Every run's painted places, one after another, made the first time they are asked for; and where
# this run's start among them.
def rg_painted_places
  @rg_painted_places ||= Array.new(@rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1, 0)
end

# Reference#request_repaint: a rebuild of the whole view is owed, and painted when something needs
# the picture. A painted screen is never built again, in a game that also has screens drawn from
# tiles: its picture is whatever the game painted there, and building the view from scenery would
# wipe it.
def rg_request_repaint
  return if @rg_kind == RG_BITMAP && @rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0

  rg_hook_repaint_requested
  @rg_rebuild_pending = true
  rg_keep_shares_for_pending_rebuild
end

# Reference#exec_scroll_rows, and anything else that changes the picture without painting it.
def rg_screen_request_rebuild = rg_request_repaint

# Reference#painted_screen?: is the screen that is up one the game paints? To the display that is a
# single background, whatever was painted on it, so it goes into blocks whole, as it is read.
def rg_painted_screen? = @rg_kind < 0 || @rg_kind == RG_BITMAP

# Reference#exec_see_through: the amounts have been worked out again for the frame about to be
# drawn, and the picture is owed when they come to other sixteenths than the ones last told.
def rg_see_through_told(layer)
  now = rg_shares_now(layer)
  return if @rg_told_shares[layer] == now

  @rg_told_shares[layer] = now
  rg_request_repaint
end

# A rebuild that rg_request_repaint would have owed, left out because nothing moved.
def rg_skip_repaint
  return if @rg_kind == RG_BITMAP && @rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0

  @rg_rebuild_skipped = true
end

# Where choice number +which+ is in a row that holds a thing's own first and then +others+ more: a
# number naming none of the others is its own.
def rg_place_of_choice(which, others) = which >= 0 && which < others ? which + 1 : 0

# IR::Affine.matrix: one over the size, held at the largest number the matrix holds; then the sine
# table, cos d being sin(d + 90). The numbers come from @rg_game_turn_rules, which the build writes
# from Ruby's own. Gives back [cos, sin].
def rg_affine_matrix(angle, size)
  scale_one, one_th, most, least_size = @rg_game_turn_rules
  scale = size < least_size ? least_size : size
  recip = (scale_one * one_th) / scale
  recip = most if recip > most
  [(@rg_game_sines[angle + 90] * recip) / one_th, (@rg_game_sines[angle] * recip) / one_th]
end

# --- sprites ---

# One picture: its pixels, where they start among them, and its size — [pixels, start, width,
# height]. A painted image's pixels are its own, from 0; any other is in @rg_game_image_pixels.
def rg_picture_of(image)
  info = RG_IMAGE_FIELDS * image
  painted = @rg_painted_images && @rg_painted_images[image]
  width = @rg_game_images[info + 1]
  height = @rg_game_images[info + 2]
  painted ? [painted, 0, width, height] : [@rg_game_image_pixels, @rg_game_images[info], width, height]
end

# Reference#run_tile_places: the 64 places of tile +which+ of a run's list, row by row. Each byte
# is two pixels, the left one in its low four bits; a byte the list does not hold reads as 0.
def rg_read_tile_places(list, which, planes, places, into)
  if planes.positive?
    first = which * planes * 8
    RG_RUN_TILE_PIXELS.times do |pixel|
      place = 0
      planes.times do |plane|
        index = first + ((plane / 2) * 16) + ((pixel / RG_RUN_TILE_SIDE) * 2) + (plane % 2)
        byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0
        place |= ((byte >> (7 - (pixel % RG_RUN_TILE_SIDE))) & 1) << plane
      end
      places[into + pixel] = place
    end
    return
  end
  (RG_RUN_TILE_PIXELS / 2).times do |at|
    index = (which * (RG_RUN_TILE_PIXELS / 2)) + at
    byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0
    places[into + (2 * at)] = byte & 0x0F
    places[into + (2 * at) + 1] = byte >> 4
  end
end

# Reference#copy_run_tiles. A run a background shows takes its tiles one after another. A run that
# is a sprite's picture has its tiles in the order a sprite's are kept, left to right and then top
# to bottom, and they are laid back out into the one picture (#copy_run_picture); then every image
# that is that picture is made again from it, each in its own colors.
def rg_tiles_copy(run, list)
  places = rg_painted_places
  first = rg_run_field(run, RG_RUN_PLACES)
  width = rg_run_field(run, RG_RUN_WIDTH)
  height = rg_run_field(run, RG_RUN_HEIGHT)
  if width == 0
    rg_run_field(run, RG_RUN_TILES).times { |which| rg_read_tile_places(list, which, rg_run_field(run, RG_RUN_PLANES), places, first + (which * RG_RUN_TILE_PIXELS)) }
    return
  end
  across = width / RG_RUN_TILE_SIDE
  tile = Array.new(RG_RUN_TILE_PIXELS, 0)
  (across * (height / RG_RUN_TILE_SIDE)).times do |which|
    rg_read_tile_places(list, which, rg_run_field(run, RG_RUN_PLANES), tile, 0)
    left = (which % across) * RG_RUN_TILE_SIDE
    top = (which / across) * RG_RUN_TILE_SIDE
    RG_RUN_TILE_PIXELS.times do |i|
      places[first + ((top + (i / RG_RUN_TILE_SIDE)) * width) + left + (i % RG_RUN_TILE_SIDE)] = tile[i]
    end
  end
  rg_paint_run_images(run)
end

# Every image that is a painted picture's run made again from its places, each in its own colors.
def rg_paint_run_images(run)
  places = rg_painted_places
  first = rg_run_field(run, RG_RUN_PLACES)
  area = rg_run_field(run, RG_RUN_WIDTH) * rg_run_field(run, RG_RUN_HEIGHT)
  @rg_painted_images ||= Array.new(@rg_game_picture_sizes[RG_SIZE_IMAGES] + 1)
  rg_run_field(run, RG_RUN_IMAGES).times do |i|
    shown_as = (rg_run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS
    image = @rg_game_run_images[shown_as]
    @rg_painted_images[image] = Array.new(area) { |at| rg_to_half(@rg_game_run_images[shown_as + 1 + places[first + at]]) }
  end
end

# rg_screen.c's rg_tile_pose_load (Reference#exec_load_sprite_tiles, for one pose).
def rg_tile_pose_load(run, pieces, piece_count, table, _kept, at, to, count)
  places = rg_painted_places
  first = rg_run_field(run, RG_RUN_PLACES)
  width = rg_run_field(run, RG_RUN_WIDTH)
  piece_count.times do |piece|
    dx = pieces[3 * piece]
    dy = pieces[(3 * piece) + 1]
    tile = pieces[(3 * piece) + 2]
    next if tile < to || tile >= to + count

    from = (at + tile - to) * (RG_RUN_TILE_PIXELS / 2)
    (RG_RUN_TILE_PIXELS / 2).times do |byte_at|
      byte = table[from + byte_at] & 0xFF
      row = byte_at / (RG_RUN_TILE_SIDE / 2)
      col = (byte_at % (RG_RUN_TILE_SIDE / 2)) * 2
      places[first + ((dy + row) * width) + dx + col] = byte & 0x0F
      places[first + ((dy + row) * width) + dx + col + 1] = byte >> 4
    end
  end
  rg_paint_run_images(run)
end

# Reference#blit_image: a see-through pixel is skipped, and each other one goes on as stored.
def rg_blit_image(image, x, y)
  art, start, width, height = rg_picture_of(image)
  return rg_blit_plain(art, start, width, height, x, y) if rg_painting_plain?

  height.times do |row|
    width.times do |col|
      color = art[start + (row * width) + col]
      rg_set_pixel(x + col, y + row, color) if color != RG_NOT_DRAWN
    end
  end
end

# rg_blit_image when painting plain (rg_painting_plain?): the picture's +width+ by +height+ pixels
# from +start+ in +art+, its corner at (x, y).
def rg_blit_plain(art, start, width, height, x, y)
  area = @rg_area
  left, right = rg_kept_span(x, x + width, RG_SCREEN_WIDTH, area.left, area.right, area.in_force)
  top, bottom = rg_kept_span(y, y + height, RG_SCREEN_HEIGHT, area.top, area.bottom, area.in_force)
  return if left >= right || top >= bottom

  target = @rg_target
  is_mixed = rg_mixes_of(target)&.is_mixed
  touched = false
  py = top
  while py < bottom
    from = start + ((py - y) * width) - x
    at = py * RG_SCREEN_WIDTH
    px = left
    while px < right
      color = art[from + px]
      if color != RG_NOT_DRAWN
        target[at + px] = color & 0xFFFF
        is_mixed[at + px] = 0 if is_mixed
        touched = true
      end
      px += 1
    end
    py += 1
  end
  @rg_picture_touched = true if touched
end

def rg_rebuilt_whole? = @rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE] != 0
# Reference#exec_blit
def rg_screen_blit(image, x, y) = rg_blit_image(image, x, y)

# Reference#exec_blit_pose: a number outside the set draws nothing.
def rg_screen_blit_pose(poses, count, pose, x, y)
  rg_blit_image(poses[pose], x, y) if pose >= 0 && pose < count
end

# Reference#exec_draw_column_at: one column of a picture, stretched to +height+ rows. The walk goes
# DOWN THE SCREEN and asks which row of the picture belongs at each screen row, the step held in
# 65536ths of a picture row and cut off at each step — the console's own rule. Only the rows on the
# screen are walked.
def rg_screen_column(image, slice, x, top, height, width)
  return if height <= 0

  art, start, art_width, art_height = rg_picture_of(image)
  column = rg_clamp_wide(slice, 0, art_width - 1)
  step = (art_height << 16) / height
  first = top < 0 ? -top : 0
  past = RG_SCREEN_HEIGHT - top < height ? RG_SCREEN_HEIGHT - top : height
  (first...past).each do |row|
    source = rg_clamp_wide((row * step) >> 16, 0, art_height - 1)
    color = art[start + (source * art_width) + column]
    next if color == RG_NOT_DRAWN

    width.times { |across| rg_set_pixel(x + across, top + row, color) }
  end
end

# Reference::FaceEdge: one edge of a face, from its upper end down, as the fill walks it. Where it
# crosses a row is #rg_face_crossing, since the game's sums are the runtime's own methods.
RgFaceEdge = Data.define(:first_row, :past_row, :at, :step) do
  def crosses?(row) = row >= first_row && row < past_row
end

# Reference::FaceEdge#at: [x, u, v, w, shade] where +edge+ crosses +row+.
def rg_face_crossing(edge, row)
  rows = rg_sub(row, edge.first_row)
  edge.at.each_with_index.map { |start, part| rg_add(start, rg_mul(edge.step[part], rows)) }
end

# The most corners a face has (Nodes::FillFace::MOST_CORNERS).
RG_FACE_MOST_CORNERS = 8

# Reference::FaceEdges.edge: the edge from +top+ to +bottom+ (each x, y, u, v, w, shade), or nil
# when it crosses no row's middle.
def rg_face_edge(top, bottom)
  first_row = rg_shr(rg_add(top[1], 7), 4)
  past_row = rg_shr(rg_add(bottom[1], 7), 4)
  return nil if first_row >= past_row

  along_row = rg_div(1 << 28, rg_sub(bottom[1], top[1]))
  into = rg_mul_fix(rg_sub(rg_add(rg_mul(first_row, 16), 8), top[1]), along_row, 4)
  parts = [rg_shl(rg_sub(bottom[0], top[0]), 12), *(2..5).map { |field| rg_sub(bottom[field], top[field]) }]
  starts = [rg_shl(top[0], 12), *top[2..5]]
  RgFaceEdge.new(first_row: first_row, past_row: past_row,
                 at: starts.zip(parts).map { |start, part| rg_add(start, rg_mul_fix(part, into, 24)) },
                 step: parts.map { |part| rg_mul_fix(part, along_row, 24) })
end

# IR::Reciprocals: 2**40 over each number of eleven bits with the top one set.
RG_FACE_RECIPROCALS = Ractor.make_shareable((1024...2048).map { |leading| (1 << 40) / leading })

# IR::Reciprocals.distance: the distance, with 16 bits of fraction, for one over it with 26.
def rg_face_distance(w)
  w = 4096 if w < 4096
  moved = w.bit_length - 11
  RG_FACE_RECIPROCALS[(w >> moved) - 1024] >> (moved - 2)
end

# Reference#place_in_perspective
def rg_face_place_in_perspective(from, steps, along)
  over = (1..3).map { |part| rg_add(from[part], rg_mul(steps[part - 1], along)) }
  distance = rg_face_distance(over[2])
  [rg_mul_fix(over[0], distance, 14), rg_mul_fix(over[1], distance, 14)]
end

# Reference::Shade#color_at: the colour +color+ becomes at +shade+ (its level in the top sixteen
# bits). A colour not in the shading's list stays as it is. Where each colour stands in the list is
# worked out once for each shading drawn with.
def rg_shaded_color(shading, color, shade)
  colors = shading[1]
  @rg_shading_places ||= {}.compare_by_identity
  places = @rg_shading_places[shading] ||= (0...colors).reverse_each.to_h { |place| [shading[2 + place], place] }
  place = places[color]
  return color if place.nil?

  rg_shaded_place(shading, place, shade)
end

# Reference::Shade#pixel_color_at: the colour place +place+ of the shading's colours becomes at
# +shade+.
def rg_shaded_place(shading, place, shade)
  colors = shading[1]
  level = rg_shr(shade, 16)
  shading[2 + shading[2 + colors + (level * colors) + place]]
end

# Reference#fill_face_row: one row of a face, from +from+ to +to+ (each x, u, v, w, shade), in
# perspective every +spans+ pixels (none when nought), each pixel through +shading+ when lit.
# +numbers+ is, for a picture given as numbers into the shading's colours, the image of those
# numbers; nil for any other.
def rg_face_row(row, from, to, left, right, image, numbers, spans, shading)
  start = rg_shr(rg_add(from[0], (1 << 15) - 1), 16)
  stop = rg_shr(rg_add(to[0], (1 << 15) - 1), 16)
  count = rg_sub(stop, start)
  return if count <= 0

  if shading # Reference::Shade#held_row_end
    from[4] = rg_clamp_wide(from[4], 0, (shading[0] << 16) - 1)
    to[4] = rg_clamp_wide(to[4], 0, (shading[0] << 16) - 1)
  end
  art, at, art_width, art_height = rg_picture_of(image)
  numbered, numbered_at, = rg_picture_of(numbers) if numbers
  steps = (1..4).map { |part| rg_div(rg_sub(to[part], from[part]), count) }
  near_at = -1
  near = far = nil
  ([start, left].max...[stop, right].min).each do |x|
    along = rg_sub(x, start)
    if spans.zero?
      u = rg_add(from[1], rg_mul(steps[0], along))
      v = rg_add(from[2], rg_mul(steps[1], along))
    else
      # Reference#place_between
      near_along = (along / spans) * spans
      far_along = [near_along + spans, count].min
      unless near_along == near_at
        near = rg_face_place_in_perspective(from, steps, near_along)
        far = rg_face_place_in_perspective(from, steps, far_along)
        near_at = near_along
      end
      u, v = near.zip(far).map do |first, last|
        rg_add(first, rg_mul(rg_div(rg_sub(last, first), far_along - near_along), along - near_along))
      end
    end
    across = rg_and(rg_shr(u, 16), art_width - 1)
    down = rg_and(rg_shr(v, 16), art_height - 1)
    color = art[at + (down * art_width) + across]
    next if color == RG_NOT_DRAWN

    if shading
      shade = rg_add(from[4], rg_mul(steps[3], along))
      color = if numbers
                rg_shaded_place(shading, numbered[numbered_at + (down * art_width) + across], shade)
              else
                rg_shaded_color(shading, color, shade)
              end
    end
    rg_set_pixel(x, row, color)
  end
end

# Reference#exec_fill_face: one face already on the screen, filled with its picture, each pixel
# through +shading+ unless it is [0] (Native::Picture#shading_array).
def rg_screen_face(pictures, picture_count, picture, corner_list, corner_count, left, top, right, bottom, spans,
                   shading)
  corner_count = RG_FACE_MOST_CORNERS if corner_count > RG_FACE_MOST_CORNERS
  return if corner_count < 3

  shading = nil if shading[0].zero?
  corners = Array.new(corner_count) do |k|
    corner = Array.new(6) { |field| rg_list_get(corner_list, (k * 6) + field) }
    # Reference::Shade#shaded_corner: the light held to 0..LIGHTEST, times the levels
    corner[5] = rg_mul(rg_clamp_wide(corner[5], 0, 0xFFFF), shading[0]) if shading
    unless spans.zero? # Reference::FaceEdges.in_perspective
      corner[2] = rg_mul_fix(corner[2], corner[4], 28)
      corner[3] = rg_mul_fix(corner[3], corner[4], 28)
    end
    corner
  end
  image = pictures[rg_clamp_wide(picture, 0, picture_count - 1)]
  left = 0 if left.negative?
  top = 0 if top.negative?
  right = RG_SCREEN_WIDTH if right > RG_SCREEN_WIDTH
  bottom = RG_SCREEN_HEIGHT if bottom > RG_SCREEN_HEIGHT
  edges = corner_count.times.filter_map do |k|
    a = corners[k]
    b = corners[(k + 1) % corner_count]
    next if a[1] == b[1]

    a[1] < b[1] ? rg_face_edge(a, b) : rg_face_edge(b, a)
  end
  return if edges.empty?

  # After the levels' places, a lit fill lists, for each of its pictures, the image of its numbers
  # into the shading's colours, or -1 for a picture of colours.
  numbers = nil
  if shading
    numbered = shading[2 + shading[1] + (shading[0] * shading[1]) + rg_clamp_wide(picture, 0, picture_count - 1)]
    numbers = numbered unless numbered.negative?
  end
  first = [edges.map(&:first_row).min, top].max
  past = [edges.map(&:past_row).max, bottom].min
  (first...past).each do |row|
    from = nil
    to = nil
    crossing = 0
    edges.each do |edge|
      next unless edge.crosses?(row)

      at = rg_face_crossing(edge, row)
      crossing += 1
      # the leftmost is the first of the leftmost, the rightmost the last of the rightmost
      from = at if from.nil? || at[0] < from[0]
      to = at if to.nil? || at[0] >= to[0]
    end
    rg_face_row(row, from, to, left, right, image, numbers, spans, shading) if crossing >= 2
  end
end

# Reference#sprites: what the game last put on screen, how many and each by its place among them as
# [whose it is, which picture it shows, x, y]. What the headless runner reads of every game, so the
# screen answers through hooks, and a game with no sprites answers none.
def rg_screen_drawn_count = rg_hook_drawn_count

def rg_screen_drawn_sprite(place) = rg_hook_drawn_sprite(place)

# --- the whole view, rebuilt (Reference#repaint_view) ---

# The fade half of Reference#set_blend_for, for the thing about to be painted: the placed fade in
# force reaches it unless that fade's layer is no further forward than +fade_place+, the furthest
# forward such a layer can be and still leave the thing as drawn. RG_NO_LAYER for a thing every
# placed fade reaches, and for the backdrop. A fade under a layer the game never declared reaches
# everything.
def rg_fade_unless_left_as_drawn(fade_place)
  under = @rg_placed_fade.layer_place
  left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under
  @rg_fading_what_is_painted = @rg_placed_fade.in_force && !left_as_drawn
end

def rg_fade_nothing
  @rg_fading_what_is_painted = false
end

# Back to front: the backdrop, then each level's scenery (rg_hook_paint_level) and its sprites,
# with what a feature paints first and last (rg_hook_repaint_began, rg_hook_repaint_ending).
def rg_repaint_view
  @rg_repaints_painted += 1
  rg_mix_nothing
  rg_fade_unless_left_as_drawn(RG_NO_LAYER)
  rg_clear_to(@rg_backdrop)
  rg_hook_repaint_began
  @rg_game_picture_sizes[RG_SIZE_DEPTHS].times do |level|
    rg_hook_paint_level(level)
  end
  rg_hook_repaint_ending
  rg_mix_nothing
  rg_fade_nothing
  @rg_picture_touched = false
end

# Reference#paint_owed_repaint. Named as the program calls it: every lowering that prints the same
# program calls this name.
def rg_screen_paint_owed_rebuild
  skipped_and_touched = @rg_rebuild_skipped && @rg_picture_touched
  @rg_rebuild_skipped = false
  if @rg_rebuild_pending || skipped_and_touched
    @rg_rebuild_pending = false
    rg_repaint_view
    rg_forget_kept_shares
  end
  rg_hook_rebuild_checked
end

# --- screens and scenes ---

# A program that waits for frames shows nothing until its first frame is set up.
def rg_screen_hold(value)
  @rg_screen_held = value
end

# Reference#exec_in_loop: while +on+ is not nought, the end of a pass is placing the frame's writes,
# and a background that pass put up still shows from its corner. Every game on a console that
# places them there sets it.
def rg_screen_placing_at_pass_end(on)
  @rg_placing_at_pass_end = on != 0
end

def rg_screen_frame_started
  @rg_screen_held = 0
  @rg_frames_begun = true
end

# The top of Reference#advance_frame. A frame boundary is the one safe moment to trade the two
# pages of a tear-free screen, so the page just drawn is shown and the game is handed the other —
# before anything can stop the run there.
def rg_screen_frame_ended
  rg_hook_frame_ended
  return if @rg_pixels.equal?(@rg_viewed)

  rg_screen_paint_owed_rebuild
  finished = @rg_pixels
  @rg_pixels = @rg_viewed
  @rg_viewed = finished
  @rg_target = @rg_pixels
  @rg_picture_touched = true # the page handed over was built before the one just shown
  rg_game_sprites_over_picture # Reference#advance_frame: placed with the page published
end

# Reference#exec_screen. Every kind of screen is a display of its own, so any change of kind wipes
# the picture and takes the scenery down (rg_hook_screen_crossed, which puts up again what every
# screen drawn from tiles shows, as declared), and returns 1 when it arrives on a screen drawn from
# tiles. A change between one page and two keeps the same picture and wipes nothing.
def rg_screen_set(new_kind, two_pages, new_backdrop)
  crossing = @rg_kind >= 0 && @rg_kind != new_kind
  if crossing
    @rg_backdrop = new_backdrop unless new_backdrop.negative?
    rg_clear_to(@rg_backdrop)
    @rg_scenery_kept = false
  else
    rg_show_backdrop(new_backdrop)
  end
  @rg_kind = new_kind
  rg_show_pages(two_pages)
  @rg_tint_by_display = rg_tint_mixed_by_display? # a tint in force is mixed this screen's way
  rg_hook_screen_set
  return 0 unless crossing

  rg_hook_screen_crossed(new_kind)
  new_kind == RG_BITMAP ? 0 : 1
end

# Reference#cross_to_scene_screen
def rg_screen_cross_to(new_kind, two_pages, new_backdrop)
  return rg_screen_set(new_kind, two_pages, new_backdrop) if @rg_kind >= 0 && @rg_kind != new_kind

  rg_show_backdrop(new_backdrop)
  0
end

# rg_screen.c's rg_screen_show_backdrop
def rg_screen_show_backdrop(color) = rg_show_backdrop(color)

# rg_screen.c's show_backdrop
def rg_show_backdrop(color)
  return if color.negative? || color == @rg_backdrop

  @rg_backdrop = color
  @rg_scenery_kept = false
  rg_hook_scenery_up ? rg_request_repaint : rg_clear_to(@rg_backdrop)
end

def rg_scene_enter(scene)
  @rg_scene = scene
end

# The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes
# down (rg_hook_scene_take_down). Whether this takeover took any down is kept for
# rg_scene_redraw_sprites to ask.
def rg_scene_take_down(brings_scenery)
  @rg_scenery_taken_down = rg_hook_scene_take_down(brings_scenery)
end

# Reference#redraw_sprites_over_arrived_scenery: the sprites of this frame were drawn as it began,
# the leaving scene's among them, and the scenery a scene put up after them covered them. The
# display draws sprites over whatever scenery is up, so the picture is built again from the scenery
# and the sprites kept when they were drawn. A painted screen is left alone. The same for a scene
# that brings none but took the last one's down, which wiped those sprites too.
def rg_scene_redraw_sprites(brings_scenery)
  return if brings_scenery == 0 && !@rg_scenery_taken_down
  return if rg_painted_screen? || !rg_hook_any_sprite_kept

  rg_request_repaint
end

# --- reading it back ---

def rg_screen_two_pages = @rg_pixels.equal?(@rg_viewed) ? 0 : 1

def rg_screen_repaints_painted = @rg_repaints_painted

# Framebuffer#to_a: the page a viewer is looking at as it is STORED, with no window moved over it
# and no fade or tint mixed in.
def rg_screen_stored
  rg_screen_paint_owed_rebuild
  @rg_viewed
end

# --- a light (Framebuffer#shade_outside) ---

def rg_shade_line = @rg_shade_row

# Where the row's span starts, and then where it ends: two calls, so the game works the left edge
# out before the right one, as the interpreter does.
def rg_shade_left(left)
  @rg_shade_spans[@rg_shade_row][0] = left
end

def rg_shade_right(right)
  @rg_shade_spans[@rg_shade_row][1] = right
end

# FadeSteps.sixteenths: the amount out of 100, in the display's sixteenths.
def rg_shade_darkness(amount)
  @rg_shade_steps = rg_whole_sixteenths(amount)
end

# Reference#work_out_shade: every row's span from the game's own expressions, top to bottom, then
# the amount.
def rg_screen_work_out_shade
  RG_SCREEN_HEIGHT.times do |row|
    @rg_shade_row = row
    rg_game_shade_span
  end
  @rg_shade_row = RG_SCREEN_HEIGHT
  rg_game_shade_amount
end

# Framebuffer#light_off=: whether the scene that just ran has the light switched off, set as the
# frame ends, before it is shown.
def rg_shade_switch(on)
  @rg_shade_off = on == 0
end

# Whether the whole screen is lit: no light darkens anything, or it is switched off.
def rg_all_lit? = @rg_shade_steps == 0 || @rg_shade_off

# Framebuffer#lit?: is (x, y) inside its row's span?
def rg_lit?(x, y)
  return true if rg_all_lit?

  left, right = @rg_shade_spans[y]
  left <= right ? x >= left && x < right : x >= left || x < right
end

# Framebuffer#shown and #pixel: the page a viewer is looking at, read through the window — off the
# edge of the picture the backdrop shows — with the fade or tint in force mixed in, read from where a
# feature says each pixel is read from (rg_hook_shown_columns, rg_hook_shown_row), and darkened
# outside a light's span. A switched-off display shows plain white.
#
# With nothing over the picture — no tint, no fade, no light, no feature reading it its own way
# (rg_hook_shown_plain) — every row is the stored row moved by the window, and is copied as one,
# which is most frames of most games.
def rg_screen_shown
  rg_keep_console_colors(rg_screen_shown_in_five_bits)
end

# Framebuffer#displayed: +shown+ as a console that keeps fewer than five bits of a channel shows it.
# Each colour's answer is kept, since a picture holds few colours and is read every frame.
def rg_keep_console_colors(shown)
  return shown if RG_COLOR_BITS >= 5

  kept = (@rg_kept_colors ||= {})
  shown.map! { |color| kept[color] ||= rg_kept_color(color) }
end

# +color+ with the top RG_COLOR_BITS of each channel, widened back to five by repeating them.
def rg_kept_color(color)
  lost = 5 - RG_COLOR_BITS
  [0, 5, 10].sum do |channel|
    level = (color >> (channel + lost)) & ((1 << RG_COLOR_BITS) - 1)
    ((level << lost) | (level >> (RG_COLOR_BITS - lost))) << channel
  end
end

def rg_screen_shown_in_five_bits
  rg_screen_paint_owed_rebuild
  shown = @rg_shown
  viewed = @rg_viewed
  held = @rg_screen_held != 0
  return shown.fill(RG_SWITCHED_OFF) if held

  front = rg_hook_front_layer # asked once a read, never once a pixel
  if @rg_tint_mode == :none && @rg_fade_steps == 0 && rg_hook_shown_plain && rg_all_lit?
    rg_screen_shown_plain(shown, viewed)
    front&.each_with_index { |color, at| shown[at] = color if color }
    return shown
  end

  # A fade or a tint does the same to every cell of one color, so each color's answer is worked out
  # once a picture (two answers: where the fade reaches and where it does not). A cell a
  # see-through layer was mixed into, under a tint, is mixed again from its own two colors, and is
  # worked out for itself (rg_shown_color).
  faded_in = Array.new(0x10000) # a cell holds sixteen bits
  faded_out = {}
  remixed = @rg_tint_mode != :none && @rg_pixels.equal?(@rg_viewed)
  mixed_cells = @rg_picture_mixes.is_mixed
  columns = rg_hook_shown_columns
  camera_x = @rg_camera_x
  whole_fade = @rg_fade_side == RG_FADE_WHOLE_SCREEN
  all_lit = rg_all_lit?
  RG_SCREEN_HEIGHT.times do |y|
    from_y = rg_hook_shown_row(y) + @rg_camera_y
    row = y * RG_SCREEN_WIDTH
    x = 0
    while x < RG_SCREEN_WIDTH
      from_x = (columns ? columns[x] : x) + camera_x
      fade_here = whole_fade || rg_fade_reaches?(x, y)
      in_front = front && front[row + x]
      color = if in_front
                rg_faded_where(in_front, fade_here) # a sprite over the picture is not in blocks
              elsif from_x >= 0 && from_x < RG_SCREEN_WIDTH && from_y >= 0 && from_y < RG_SCREEN_HEIGHT
                at = (from_y * RG_SCREEN_WIDTH) + from_x
                stored = viewed[at]
                if remixed && mixed_cells[at] != 0
                  rg_shown_color(at, stored, fade_here)
                else
                  answers = fade_here ? faded_in : faded_out
                  answers[stored] ||= rg_faded_where(stored, fade_here)
                end
              else
                rg_faded_where(0, fade_here)
              end
      shown[row + x] = all_lit || rg_lit?(x, y) ? color : rg_darkened_by_display(color, @rg_shade_steps)
      x += 1
    end
  end
  shown
end

# rg_screen_shown with nothing over the picture: each row the stored row the window sits over, and
# off the picture the backdrop, which is nought (rg_faded_where with nothing in force).
def rg_screen_shown_plain(shown, viewed)
  camera_x = @rg_camera_x
  camera_y = @rg_camera_y
  RG_SCREEN_HEIGHT.times do |y|
    row = y * RG_SCREEN_WIDTH
    from_y = y + camera_y
    if from_y < 0 || from_y >= RG_SCREEN_HEIGHT
      shown.fill(0, row, RG_SCREEN_WIDTH)
    elsif camera_x == 0
      shown[row, RG_SCREEN_WIDTH] = viewed[from_y * RG_SCREEN_WIDTH, RG_SCREEN_WIDTH]
    else
      from_row = from_y * RG_SCREEN_WIDTH
      x = 0
      while x < RG_SCREEN_WIDTH
        from_x = x + camera_x
        shown[row + x] = from_x >= 0 && from_x < RG_SCREEN_WIDTH ? viewed[from_row + from_x] : 0
        x += 1
      end
    end
  end
  shown
end
