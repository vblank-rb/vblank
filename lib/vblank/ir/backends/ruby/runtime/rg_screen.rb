# THE GAME'S PICTURE, drawn in software: the console's screen as an array of colors, and
# everything the game does to it — drawing, the window over the picture, see-through layers and
# bends. What only some games use (backgrounds, sprites, fades and tints, a picture in blocks, the
# light, stretched columns, the faces of a place) is a runtime feature of its own, under runtime_features/.
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

RG_NOT_DRAWN = -1      # A sprite picture's pixel where what is behind shows
RG_SEE_THROUGH = 0xFFFF # A tile's pixel where the layer behind shows

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
# the color table, which reaches each side before the mix (see the filter's +remix+). +is_mixed+ is
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

# A FILTER for reading the picture back, which a feature hands over once a read (rg_hook_fade_filter,
# rg_hook_dim_filter) and the loop in rg_screen_shown reads: +table+ is the colour shown for each colour a
# cell holds, looked up with table[color]; +everywhere+ is whether it applies to every pixel; +rows+, when
# it does not, is [from, to, inverted] for each screen row, a pixel being changed when +inverted+ differs
# from from <= x < to; +remix+ is whether a see-through mixed cell is mixed again from its two sides, each
# through the table; +changes+ counts the times the table was emptied to be worked out again for other
# settings (the same Hash kept), for an answer kept from it (rg_colors_through), nil for a table never emptied.
RgShownFilter = Struct.new(:table, :everywhere, :rows, :remix, :changes)

# Where image +image+'s pieces are: [the array, where they start in it] (rg_screen.h,
# rg_screen_image_pieces): those the start file lists for it, or else the game's own.
def rg_screen_image_pieces(image)
  read = @rg_image_pieces_read[image]
  read ? [read, 0] : [@rg_game_image_pieces, @rg_game_image_pieces[2 + image]]
end

# +pieces+, how many and then four numbers each, are image +image+'s from now on (rg_screen.h,
# rg_screen_read_image_pieces).
def rg_screen_read_image_pieces(image, pieces)
  @rg_image_pieces_read[image] = pieces
end

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
  # The pieces of each image the start file lists, by the image's number (#rg_screen_read_image_pieces).
  @rg_image_pieces_read = {}
  @rg_screen_held = 0 # switched off until the first frame (Framebuffer#held=)
  @rg_frames_begun = false # a frame boundary has been reached (Reference @uses_frames)
  # Made the first time each is needed; named here so the game's shape never changes in play.
  @rg_painted_places = nil
  @rg_painted_images = nil
  @rg_kept_colors = nil
  @rg_scenery_taken_down = false # the last scene to take over took scenery down
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
  # The colour table what is painted goes through (Framebuffer @paint_toward), or nil to paint it as
  # drawn. Set only while the view is rebuilt, for the things a placed fade reaches.
  @rg_paint_fade = nil
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
  # WHAT THE GAME HAS PAINTED (Reference @bitmaps, for a run's tiles and pictures): every run's
  # pixels as places in its colors, place 0 see-through; and the images painted from them.
  @rg_painted_places = nil
  @rg_painted_images = nil
  @rg_runs_painted = nil
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

# Framebuffer#apply_placed_fade: a color as it is painted, through the table a placed fade handed over
# (@rg_paint_fade) while one reaches the thing painted. The color is held to the sixteen bits a cell
# holds either way.
def rg_faded_as_painted(color)
  color &= 0xFFFF
  table = @rg_paint_fade
  table ? table[color] : color
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
def rg_painting_plain? = !@rg_plain_layer && !@rg_mixing && !@rg_paint_fade && !rg_keeps_picture_without_sprites?

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

# Reference#set_see_through_for, for scenery: mixing on for a thing in a see-through layer, off for
# anything else. +layer+ is RG_SOLID for a thing in none.
def rg_mix_as_layer(layer)
  @rg_painting_sprite = false
  @rg_mixing = layer != RG_SOLID && !rg_hook_blend_held_by_fade
  return unless @rg_mixing

  @rg_mixed_by = @rg_mixed_cells_by = @rg_pending_shares[layer] || rg_shares_now(layer)
end

def rg_mix_nothing
  @rg_mixing = false
  @rg_painting_sprite = false
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

# Which runs' images have been painted from their places, 1 or 0 by run (rg_screen.c's runs_painted).
def rg_runs_painted
  @rg_runs_painted ||= Array.new(@rg_game_picture_sizes[RG_SIZE_RUNS] + 1, 0)
end

# Every image that is a painted picture's run made again from its places, each in its own colors.
def rg_paint_run_images(run)
  rg_runs_painted[run] = 1
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

# Reference#sprites: what the game last put on screen, how many and each by its place among them as
# [whose it is, which picture it shows, x, y]. What the headless runner reads of every game, so the
# screen answers through hooks, and a game with no sprites answers none.
def rg_screen_drawn_count = rg_hook_drawn_count

def rg_screen_drawn_sprite(place) = rg_hook_drawn_sprite(place)

# --- the whole view, rebuilt (Reference#repaint_view) ---

# The fade half of Reference#set_blend_for, for the thing about to be painted: what is painted from
# here on goes through the colour table a placed fade asks for it (rg_hook_paint_fade_for), or as
# drawn where none does. +fade_place+ is the furthest forward a placed fade's layer can be and still
# leave the thing as drawn; RG_NO_LAYER for a thing every placed fade reaches, and for the backdrop.
# Asked once a thing painted, never once a pixel.
def rg_fade_unless_left_as_drawn(fade_place)
  @rg_paint_fade = rg_hook_paint_fade_for(fade_place)
end

def rg_fade_nothing
  @rg_paint_fade = nil
end

# Reference#placed_fade_in_picture?: a placed fade in force changes the backdrop, which is behind
# everything, unless it is one of no amount. Scenery stamped as drawn is then not the picture, and
# what stamps it asks for the view to be rebuilt.
def rg_placed_fade_in_picture? = !rg_hook_paint_fade_for(RG_NO_LAYER).nil?

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

# Framebuffer#shown and #pixel: the page a viewer is looking at, read through the window — off the
# edge of the picture the backdrop shows — read from where a feature says each pixel is read from
# (rg_hook_shown_columns, rg_hook_shown_row), with the layer a feature shows in front laid over it
# (rg_hook_front_layer), then through the fade's colour table where that reaches the pixel and the
# light's where that does. A switched-off display shows plain white.
#
# The fade and the light are filters (RgShownFilter) a feature hands over once a read
# (rg_hook_fade_filter, rg_hook_dim_filter), and the loop only reads the tables they hold.
#
# With nothing over the picture — no filter, no feature reading it its own way
# (rg_hook_shown_plain) — every row is the stored row moved by the window, and is copied as one,
# which is most frames of most games.
def rg_screen_shown
  rg_keep_console_colors(rg_black_rows_given_up(rg_screen_shown_in_five_bits))
end

# rg_screen.c's black_rows_given_up: the rows the game gave up (`shown_rows:`) black, unless the
# display is switched off.
def rg_black_rows_given_up(shown)
  return shown if @rg_screen_held != 0 || (RG_SHOWN_FIRST_ROW.zero? && RG_SHOWN_PAST_ROW == RG_SCREEN_HEIGHT)

  shown.fill(0, 0, RG_SHOWN_FIRST_ROW * RG_SCREEN_WIDTH)
  shown.fill(0, RG_SHOWN_PAST_ROW * RG_SCREEN_WIDTH, (RG_SCREEN_HEIGHT - RG_SHOWN_PAST_ROW) * RG_SCREEN_WIDTH)
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
  return shown.fill(RG_SWITCHED_OFF) if @rg_screen_held != 0

  # Each asked once a read, never once a pixel.
  front = rg_hook_front_layer
  fade = rg_hook_fade_filter
  dim = rg_hook_dim_filter
  if !fade && !dim && rg_hook_shown_plain
    rg_screen_shown_plain(shown, viewed)
    front&.each_with_index { |color, at| shown[at] = color if color }
    return shown
  end

  # What the loop reads is taken out of the filters first, so a pixel costs table lookups and
  # comparisons and no call. A table is a Hash that works a colour's answer out the first time it
  # is asked and keeps it, so a lookup is a plain table[color].
  columns = rg_hook_shown_columns
  camera_x = @rg_camera_x
  fade_table = fade&.table
  fade_all = fade ? fade.everywhere : false
  fade_rows = fade&.rows
  remix = fade ? fade.remix : false
  dim_table = dim&.table
  dim_all = dim ? dim.everywhere : false
  dim_rows = dim&.rows
  mixes = @rg_picture_mixes
  mixed_cells = mixes.is_mixed
  tops = mixes.tops
  unders = mixes.unders
  mixed_by = @rg_mixed_cells_by
  # A row read straight across, with a fade or tint over all of it or none, and no layer in front, no
  # light and no feature moving its columns, is the stored row turned through the fade's table as one
  # (rg_screen_shown_row_through): no lookup and no comparison a pixel.
  whole_rows = !front && !dim && !columns && camera_x == 0 && (!fade || fade_all)
  lookup = whole_rows && fade ? rg_colors_through(fade) : nil
  RG_SCREEN_HEIGHT.times do |y|
    from_y = rg_hook_shown_row(y) + @rg_camera_y
    row = y * RG_SCREEN_WIDTH
    if whole_rows && from_y >= 0 && from_y < RG_SCREEN_HEIGHT
      from = from_y * RG_SCREEN_WIDTH
      # A mixed cell (marked 1, and every other cell 0) is mixed again through the table, a pixel at a time below.
      unless remix && rg_row_has_mixed_cell?(mixed_cells, from)
        rg_screen_shown_row_through(shown, row, viewed, from, lookup, fade_table)
        next
      end
    end
    # Where a filter does not apply everywhere, its row says [from, to, inverted]: a pixel is
    # changed when inverted differs from from <= x < to.
    fade_row = fade && !fade_all ? fade_rows[y] : nil
    fade_from = fade_row ? fade_row[0] : 0
    fade_to = fade_row ? fade_row[1] : 0
    fade_inverted = fade_row ? fade_row[2] : false
    dim_row = dim && !dim_all ? dim_rows[y] : nil
    dim_from = dim_row ? dim_row[0] : 0
    dim_to = dim_row ? dim_row[1] : 0
    dim_inverted = dim_row ? dim_row[2] : false
    x = 0
    while x < RG_SCREEN_WIDTH
      fade_here = fade_all || (fade_row ? fade_inverted != (x >= fade_from && x < fade_to) : false)
      in_front = front && front[row + x]
      color = if in_front
                fade_here ? fade_table[in_front] : in_front # a sprite over the picture is not in blocks
              else
                from_x = (columns ? columns[x] : x) + camera_x
                if from_x >= 0 && from_x < RG_SCREEN_WIDTH && from_y >= 0 && from_y < RG_SCREEN_HEIGHT
                  at = (from_y * RG_SCREEN_WIDTH) + from_x
                  if remix && mixed_cells[at] != 0
                    # Framebuffer#shown_color: a mixed cell is mixed again from its two sides, each through the table
                    rg_mixed_with_under(fade_table[tops[at]], fade_table[unders[at]], mixed_by)
                  else
                    fade_here ? fade_table[viewed[at]] : viewed[at]
                  end
                else
                  fade_here ? fade_table[0] : 0
                end
              end
      color = dim_table[color] if dim_table && (dim_all || (dim_row ? dim_inverted != (x >= dim_from && x < dim_to) : false))
      shown[row + x] = color
      x += 1
    end
  end
  shown
end

# How many colours a cell can hold: sixteen bits.
RG_CELL_COLORS = 0x10000

# NO SLICES OF THE SCREEN'S ARRAYS. A slice of a long Array (viewed[from, RG_SCREEN_WIDTH]) is not a
# copy: it shares the Array's storage, and the next write to the Array then copies the whole screen's
# worth of storage first, since the slice still looks at the old one. Reading the picture a row at a
# time that way copied each page several times a pass, and the memory those copies took made Ruby
# collect garbage often and, every few seconds, mark every object the process holds, which stopped
# the game for several frames. So the picture is read here by index, and copied whole with
# Array#[]= (which copies the elements and shares nothing).

# Whether the row of +mixed_cells+ that starts at +from+ marks any cell mixed.
def rg_row_has_mixed_cell?(mixed_cells, from)
  at = from
  last = from + RG_SCREEN_WIDTH
  while at < last
    return true if mixed_cells[at] != 0

    at += 1
  end
  false
end

# A fade's or tint's +table+ (a Hash that works a colour out the first time it is asked) kept again
# as an Array, a place for every colour a cell can hold, nil until the colour is first asked, so a
# pixel is turned through it by an index where the Hash takes a call a colour. Emptied when the
# filter hands over another table, or empties its own (+changes+), which it does as the fade or tint
# moves: the one Array is kept, so a moving fade takes no new memory a pass for it.
def rg_colors_through(filter)
  lookup = (@rg_colors_through ||= Array.new(RG_CELL_COLORS))
  table = filter.table
  return lookup if @rg_colors_through_table.equal?(table) && @rg_colors_through_changes == filter.changes

  @rg_colors_through_table = table
  @rg_colors_through_changes = filter.changes
  lookup.fill(nil)
end

# One row of the picture: the stored row from +from+, through +lookup+ (rg_colors_through of
# +table+) where a fade or tint is over it, into +shown+ at +row+. A colour not asked before is
# worked out by the table first; a colour no cell holds goes through the table itself.
def rg_screen_shown_row_through(shown, row, viewed, from, lookup, table)
  x = 0
  while x < RG_SCREEN_WIDTH
    color = viewed[from + x]
    shown[row + x] = if !lookup
                       color
                     elsif color >= 0 && color < RG_CELL_COLORS
                       lookup[color] || (lookup[color] = table[color])
                     else
                       table[color]
                     end
    x += 1
  end
end

# rg_screen_shown with nothing over the picture: each row the stored row the window sits over, and
# off the picture the backdrop, which is nought. A window moved only up or down is the picture copied
# whole (no slice: see rg_row_has_mixed_cell?), turned round by the rows it moved, and the rows that
# came round from the other edge filled with the backdrop.
def rg_screen_shown_plain(shown, viewed)
  camera_x = @rg_camera_x
  camera_y = @rg_camera_y
  if camera_x == 0
    shown[0, RG_SCREEN_CELLS] = viewed
    return shown if camera_y == 0
    return shown.fill(0) if camera_y.abs >= RG_SCREEN_HEIGHT

    shown.rotate!(camera_y * RG_SCREEN_WIDTH)
    off = camera_y.abs * RG_SCREEN_WIDTH
    return camera_y.positive? ? shown.fill(0, RG_SCREEN_CELLS - off) : shown.fill(0, 0, off)
  end

  RG_SCREEN_HEIGHT.times do |y|
    row = y * RG_SCREEN_WIDTH
    from_y = y + camera_y
    if from_y < 0 || from_y >= RG_SCREEN_HEIGHT
      shown.fill(0, row, RG_SCREEN_WIDTH)
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

# --- the screen's half of the state image (rg_screen.c's rg_screen_visit_state) ---

# A flag kept as true or false, or as a number, written as 1 or 0.
def rg_state_flag(value) = value == true || (value.is_a?(Integer) && value != 0) ? 1 : 0

def rg_page_number(page)
  return 0 if page.equal?(@rg_first_page)

  page.equal?(@rg_second_page) ? 1 : 2
end

def rg_page_from_number(number)
  unless number.between?(0, 2)
    rg_state_refuse_damaged("the screen names a page it does not have")
  end
  [@rg_first_page, @rg_second_page, @rg_scenery][number]
end

def rg_visit_mixes(name, mixes)
  values = rg_state_numbers(name, [*mixes.is_mixed, *mixes.tops, *mixes.unders])
  # Copied in rather than replaced with a slice, which would share the slice's storage (see
  # rg_row_has_mixed_cell?).
  mixes.is_mixed[0, RG_SCREEN_CELLS] = values[0, RG_SCREEN_CELLS]
  mixes.tops[0, RG_SCREEN_CELLS] = values[RG_SCREEN_CELLS, RG_SCREEN_CELLS]
  mixes.unders[0, RG_SCREEN_CELLS] = values[2 * RG_SCREEN_CELLS, RG_SCREEN_CELLS]
end

# How many areas are open around the one in force, then that one, then each open around it, the
# outermost first; the slots past those open are noughts.
RG_AREA_NUMBERS = 5  # In force, left, top, right, bottom
RG_SHARE_NUMBERS = 3 # Kept, what is painted, what is under it

def rg_visit_areas
  values = Array.new(1 + (RG_AREA_NUMBERS * (RG_AREAS_DEEP + 1)), 0)
  values[0] = @rg_outer_areas.length
  [@rg_area, *@rg_outer_areas].each_with_index do |area, i|
    values[1 + (RG_AREA_NUMBERS * i), RG_AREA_NUMBERS] = [rg_state_flag(area.in_force), area.left, area.top, area.right, area.bottom]
  end
  rg_state_numbers("screen.areas", values)
  unless values[0].between?(0, RG_AREAS_DEEP)
    rg_state_refuse_damaged("the screen holds more areas than it can")
  end
  areas = (0..values[0]).map do |i|
    in_force, left, top, right, bottom = values[1 + (RG_AREA_NUMBERS * i), RG_AREA_NUMBERS]
    RgArea.new(in_force != 0, left, top, right, bottom)
  end
  @rg_area = areas.first
  @rg_outer_areas = areas.drop(1)
end

# Each see-through layer's shares kept for the owed rebuild, then those last told: kept, and the two
# shares (nil here is not kept).
def rg_visit_kept_shares
  sides = [@rg_pending_shares, @rg_told_shares]
  values = sides.flat_map do |side|
    side.flat_map { |shares| shares ? [1, *shares] : [0, 0, 0] }
  end
  rg_state_numbers("screen.shares", values)
  sides.each_with_index do |side, s|
    RG_MAX_SEE_THROUGH.times do |layer|
      kept, painted, under = values[RG_SHARE_NUMBERS * ((s * RG_MAX_SEE_THROUGH) + layer), RG_SHARE_NUMBERS]
      side[layer] = kept != 0 ? [painted, under] : nil
    end
  end
end

# What the game painted into its runs, and which runs' images were painted from them: on reading,
# those images are painted again from the places read, and any other run's go back to as built.
def rg_visit_runs
  runs = @rg_game_picture_sizes[RG_SIZE_RUNS]
  places = rg_painted_places
  count = @rg_game_picture_sizes[RG_SIZE_RUN_PIXELS]
  places[0, count] = rg_state_numbers("screen.runs.places", places.first(count))
  painted = rg_state_numbers("screen.runs.painted", rg_runs_painted.first(runs))
  return unless rg_state_reading

  runs.times do |run|
    next rg_paint_run_images(run) if painted[run] != 0

    rg_run_field(run, RG_RUN_IMAGES).times do |i|
      @rg_painted_images[@rg_game_run_images[(rg_run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS]] = nil if @rg_painted_images
    end
  end
end

def rg_screen_visit_state
  numbers = [
    rg_page_number(@rg_pixels), rg_page_number(@rg_viewed), rg_page_number(@rg_target), @rg_screen_held,
    rg_state_flag(@rg_frames_begun), @rg_kind, rg_state_flag(@rg_rebuild_pending), rg_state_flag(@rg_rebuild_skipped),
    rg_state_flag(@rg_picture_touched), @rg_backdrop, @rg_scene, rg_state_flag(@rg_scenery_kept),
    rg_state_flag(@rg_painting_sprite), rg_state_flag(@rg_placing_at_pass_end), rg_state_flag(@rg_scenery_taken_down),
    @rg_camera_x, @rg_camera_y, *@rg_mixed_cells_by
  ]
  rg_state_numbers("screen", numbers)
  @rg_pixels, @rg_viewed, @rg_target = numbers[0, 3].map { |number| rg_page_from_number(number) }
  @rg_screen_held = numbers[3]
  @rg_frames_begun, @rg_rebuild_pending, @rg_rebuild_skipped, @rg_picture_touched = numbers.values_at(4, 6, 7, 8).map { |n| n != 0 }
  @rg_kind, @rg_backdrop, @rg_scene = numbers.values_at(5, 9, 10)
  @rg_scenery_kept, @rg_painting_sprite, @rg_placing_at_pass_end, @rg_scenery_taken_down = numbers[11, 4].map { |n| n != 0 }
  @rg_camera_x, @rg_camera_y = numbers[15, 2]
  @rg_mixed_cells_by = numbers[17, 2]
  rg_state_numbers("screen.page.first", @rg_first_page)
  rg_state_numbers("screen.page.second", @rg_second_page)
  rg_state_numbers("screen.scenery", @rg_scenery)
  rg_state_numbers("screen.without_sprites", @rg_picture_without_sprites)
  rg_visit_mixes("screen.mixes.picture", @rg_picture_mixes)
  rg_visit_mixes("screen.mixes.scenery", @rg_scenery_mixes)
  rg_visit_areas
  rg_visit_kept_shares
  rg_visit_runs
  rg_hook_visit_state
end

# A patch of picture kept under a sprite: whether it was saved, then its cells (rg_state.h).
def rg_patch_visit_state(name, buffer, width, height)
  cells = width * height
  patch = @rg_saved_patches[buffer]
  values = rg_state_numbers(name, patch ? [1, *patch.first(cells)] : [0, *Array.new(cells, RG_NO_CELL)])
  @rg_saved_patches[buffer] = values[0] != 0 ? values.drop(1) : nil
end
