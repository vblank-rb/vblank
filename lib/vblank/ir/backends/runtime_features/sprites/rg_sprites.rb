# frozen_string_literal: true

# SPRITES AND THEIR DRAW ORDER (Reference#exec_present_objects and the sprites it keeps): the sprites
# on screen this frame, taken off and put back on a picture that stays, kept for a picture that is
# built again, turned and resized, left out of a crowded line, shown over a painted screen, and put
# into blocks while the picture is pixelated. Also the order a worked-out draw order places them in,
# and the collision test that reads their pictures. A runtime feature (backends/runtime_features.rb):
# joined into the runtime's class after rg_screen.rb for a game that declares a sprite. rg_sprites.c
# says how, rule for rule; this is that file written again, method for method.

# The state of the sprites: those on screen this frame (being set) and as the last rebuild draws them,
# where each was last drawn straight onto the picture by its number (Reference @obj_prev), the layer in
# front of a painted picture (one colour or nil for each cell; nil itself while none is up), and the
# size of the blocks a kept sprite is being painted in.
def rg_sprites_setup
  @rg_drawing = []
  @rg_sprite_layer = []
  @rg_last_drawn = Array.new(RG_MAX_SPRITES)
  @rg_over_picture = nil
  @rg_sprite_block = 1
end

# One sprite on screen this frame. One that turns or resizes carries its angle and its size for
# this frame, and whether its size ever changes. One that loses slices to a crowded line keeps them
# as +cuts+, [line, piece] each (#rg_mark_slices_left_out).
RgPlaced = Struct.new(:sprite, :image, :x, :y, :level, :turned, :angle, :size, :resizes, :cuts)


RG_NO_PLACE = -1
# The display counts the rows of a turned sprite's box in this many lines that come round.
RG_TURNED_BOX_LINES = 256

# Reference#set_see_through_for, for a sprite: the same, and what is painted is a sprite's, so it
# is mixed with the picture as it is with no sprite on it and stays off that picture.
def rg_mix_as_sprite(sprite)
  rg_mix_as_layer(@rg_game_sprite_see_through[sprite])
  @rg_painting_sprite = true
end


# The screen row the box row +row+ of a turned sprite lands on when the box's first row is at
# +top+, or -1 for a line below the screen, where the box stands unseen (Reference::TurnedBox): the
# display counts the rows of a sprite's box in lines that come round, and the screen is fewer.
def rg_turned_box_line(top, row)
  line = (top + row) % RG_TURNED_BOX_LINES
  line < RG_SCREEN_HEIGHT ? line : -1
end

# TurnedBox.rows_shown's first test, with Affine.rows_reached: a sprite is drawn at all only while
# some of the rows its picture can reach are on the screen. A picture that +resizes+ can fill its
# whole box; one that only turns stays within a square as wide as its diagonal, and a pixel each
# side, about the middle.
def rg_turned_box_on_screen?(top, width, height, resizes)
  first = 0
  past = height * 2
  if resizes == 0
    reach = Integer.sqrt((width * width) + (height * height)) + 2
    first = height - (reach / 2)
    past = first + reach
  end
  top + past > 0 && top + first < RG_SCREEN_HEIGHT
end

# Reference#blit_image_transformed: a picture turned +angle+ degrees clockwise and drawn at +size+,
# about its own middle, its top left as drawn at (x, y). The console walks the patch of screen the
# sprite can cover — twice the picture each way, centered on it — and for each pixel works BACK
# through the turn to the pixel of the picture that lands there; one that falls outside the picture
# is not drawn. A screen pixel is taken at its whole coordinate and the answer rounded down.
def rg_blit_image_turned(image, x, y, angle, size, resizes)
  art, start, width, height = rg_picture_of(image)
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(angle % 360, size)
  left = x - (width / 2)
  top = y - (height / 2)
  return unless rg_turned_box_on_screen?(top, width, height, resizes)

  (height * 2).times do |iy|
    line = rg_turned_box_line(top, iy)
    next if line < 0

    dy = iy - height
    (width * 2).times do |ix|
      dx = ix - width
      from_x = (((turn_cos * dx) + (turn_sin * dy)) / one_th) + (width / 2)
      from_y = (((-turn_sin * dx) + (turn_cos * dy)) / one_th) + (height / 2)
      next if from_x < 0 || from_x >= width || from_y < 0 || from_y >= height

      color = art[start + (from_y * width) + from_x]
      rg_set_pixel(left + ix, line, color) if color != RG_NOT_DRAWN
    end
  end
end

# --- how many sprites a line of the screen shows (rg_screen.c's, Backends::SpriteLines) ---
#
# @rg_game_image_pieces: how tall a piece is, then where each image's pieces start, and there how
# many, then each one's across and down. RG_SPRITE_PIECES_A_LINE is 0 where every piece is drawn.
RG_PIECE_WIDTH = 8

# Reference#mark_slices_left_out: each sprite that loses slices to a crowded line keeps them as its
# +cuts+. The table lists them front-most first: the deepest level last, and inside a level the one
# drawn last first.
def rg_mark_slices_left_out(placed)
  placed.each { |sprite| sprite.cuts = nil }
  return if RG_SPRITE_PIECES_A_LINE == 0 || placed.empty?

  pieces = @rg_game_image_pieces
  tall = pieces[0]
  taken = Array.new(RG_SCREEN_HEIGHT, 0)
  placed.each_index.sort_by { |at| [placed[at].level, at] }.reverse_each do |at|
    sprite = placed[at]
    start = pieces[1 + sprite.image]
    cuts = []
    pieces[start].times do |piece|
      left = sprite.x + pieces[start + 1 + (2 * piece)]
      top = sprite.y + pieces[start + 2 + (2 * piece)]
      next if left <= -RG_PIECE_WIDTH || left >= RG_SCREEN_WIDTH

      ([top, 0].max...[top + tall, RG_SCREEN_HEIGHT].min).each do |line|
        cuts << [line, piece] if taken[line] >= RG_SPRITE_PIECES_A_LINE
        taken[line] += 1
      end
    end
    sprite.cuts = cuts unless cuts.empty?
  end
end

# SpriteLines.left_out_at?: left out where a piece left out of the line covers it and no piece
# drawn there does.
def rg_left_out_at?(placed, col, row, line)
  pieces = @rg_game_image_pieces
  start = pieces[1 + placed.image]
  tall = pieces[0]
  covered = false
  pieces[start].times do |piece|
    across = pieces[start + 1 + (2 * piece)]
    down = pieces[start + 2 + (2 * piece)]
    next if col < across || col >= across + RG_PIECE_WIDTH || row < down || row >= down + tall
    return false unless placed.cuts.include?([line, piece])

    covered = true
  end
  covered
end

# Reference#blit_image with a sprite's slices left out.
def rg_blit_with_slices_left_out(placed)
  art, start, width, height = rg_picture_of(placed.image)
  height.times do |row|
    line = placed.y + row
    width.times do |col|
      color = art[start + (row * width) + col]
      rg_set_pixel(placed.x + col, line, color) if color != RG_NOT_DRAWN && !rg_left_out_at?(placed, col, row, line)
    end
  end
end

# Reference#draw_object and #paint_snapshot_object
def rg_draw_placed(placed)
  if placed.turned
    rg_blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes)
  elsif placed.cuts
    rg_blit_with_slices_left_out(placed)
  else
    rg_blit_image(placed.image, placed.x, placed.y)
  end
end



# Reference#scene_framebuffer: the backdrop, and every background showing stamped over it
# (rg_hook_stamp_scenery). It is a picture of its own, so an area the game's drawing is held to
# does not hold this.
def rg_keep_scenery
  return if @rg_scenery_kept

  outer = @rg_area
  @rg_area = RgArea.new(false, 0, 0, 0, 0)
  @rg_target = @rg_scenery
  rg_clear_to(@rg_backdrop)
  rg_hook_stamp_scenery
  @rg_target = @rg_pixels
  @rg_area = outer
  @rg_scenery_kept = true
end


# The start of Reference#exec_present_objects. A game that draws its sprites straight onto the
# picture has the scenery under them kept from here, as the interpreter does.
def rg_objects_begin
  @rg_drawing = []
  rg_keep_scenery unless rg_rebuilt_whole?
end

def rg_fault_unless_sprite(sprite)
  return if sprite >= 0 && sprite < RG_MAX_SPRITES

  rg_fault("sprite number #{sprite} is not one of the #{RG_MAX_SPRITES} there is room for")
end

# Framebuffer#put_back_cell: the scenery's cell at (x, y) put back on the picture, a mix kept as one
# so that a tint still reaches both its sides.
def rg_put_back_cell(x, y)
  at = (y * RG_SCREEN_WIDTH) + x
  rg_set_pixel(x, y, @rg_scenery[at])
  kept = rg_mixes_of(@rg_target)
  return if !kept || !rg_paintable?(x, y) || @rg_scenery_mixes.is_mixed[at] == 0

  kept.is_mixed[at] = 1
  kept.tops[at] = @rg_scenery_mixes.tops[at]
  kept.unders[at] = @rg_scenery_mixes.unders[at]
end

# Reference#restore_patch: the scenery put back over a patch of the picture.
def rg_restore_patch(left, top, width, height)
  height.times do |row|
    width.times do |col|
      x = left + col
      y = top + row
      rg_put_back_cell(x, y) if rg_on_screen?(x, y)
    end
  end
end

# The same over a turned sprite's patch, each row on the screen row the display counts it at.
def rg_restore_turned_patch(left, top, width, height)
  height.times do |row|
    line = rg_turned_box_line(top, row)
    rg_restore_patch(left, line, width, 1) if line >= 0
  end
end

# Forgets where a sprite was last drawn straight onto the picture, and hands that place over for
# the scenery to be put back there; nil when it is not on the picture.
def rg_forget_drawn_place(sprite)
  rg_fault_unless_sprite(sprite)
  place = @rg_last_drawn[sprite]
  @rg_last_drawn[sprite] = nil
  place
end

# Reference#restore_scene_rect: the scenery put back where this sprite was last drawn, over the
# box every one of its pictures fits in, +width+ by +height+ (SpriteCut.canvas_of).
def rg_object_take_off(sprite, width, height)
  place = rg_forget_drawn_place(sprite)
  return unless place

  x, y = place
  rg_restore_patch(x, y, width, height)
end

# Reference#restore_scene_rect and #transformed_footprint, for a sprite that turns or resizes. The
# patch has to hold the picture at whatever angle and size it was last drawn. One that only turns
# reaches no further from its middle than half its own diagonal, so a square that wide does; one
# that +resizes+ has no bound short of the whole box the display gives it, twice the picture each
# way. Each row is put back on the screen row it was drawn on.
def rg_object_take_off_turned(sprite, image, resizes)
  place = rg_forget_drawn_place(sprite)
  return unless place

  x, y = place
  _, _, width, height = rg_picture_of(image)
  middle_x = x + (width / 2)
  middle_y = y + (height / 2)
  return rg_restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2) if resizes != 0

  side = Integer.sqrt((width * width) + (height * height)) + 2
  rg_restore_turned_patch(middle_x - (side / 2), middle_y - (side / 2), side, side)
end

# One more sprite on screen this frame.
def rg_add_placed(placed)
  rg_fault_unless_sprite(placed.sprite)
  rg_fault("more than #{RG_MAX_SPRITES} sprites on screen at once") if @rg_drawing.length >= RG_MAX_SPRITES
  @rg_drawing << placed
end

def rg_objects_add(sprite, image, x, y, level)
  rg_add_placed(RgPlaced.new(sprite, image, x, y, level, false, 0, 0, 0))
end

def rg_objects_add_turned(sprite, image, x, y, level, angle, size, resizes)
  rg_add_placed(RgPlaced.new(sprite, image, x, y, level, true, angle, size, resizes))
end

# The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
# screen now are kept (#snapshot_object_layer) and the rebuild is owed, unless they are the sprites,
# in the same places, that the last rebuild painted: the interpreter builds it every time, and this
# only when something moved. On one that is not rebuilt whole, each is drawn where it is now, and
# where that was is remembered for taking it off again. Kept whichever way the picture is made: a
# scene taking over later in this pass builds the picture again from it.
def rg_objects_end
  rg_mark_slices_left_out(@rg_drawing)
  kept = @rg_sprite_layer
  @rg_sprite_layer = @rg_drawing.dup
  # Reference#show_objects_over_picture: in the layer in front of a painted picture, never into it.
  if @rg_kind == RG_BITMAP && @rg_game_picture_sizes[RG_SIZE_SPRITES_OVER_PICTURE] != 0
    @rg_over_picture = Array.new(RG_SCREEN_CELLS)
    rg_paint_onto_plain_layer(@rg_over_picture)
    @rg_drawing.each { |placed| rg_draw_placed(placed) }
    rg_paint_onto_plain_layer(nil)
    @rg_over_picture = nil if @rg_drawing.empty?
    return
  end
  if rg_rebuilt_whole?
    return rg_skip_repaint if @rg_drawing == kept

    return rg_request_repaint
  end
  # The sprite layer is off while a painted screen is up in a game with screens drawn from tiles.
  return if @rg_kind == RG_BITMAP && @rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE] != 0

  @rg_drawing.each do |placed|
    rg_mix_as_sprite(placed.sprite)
    rg_draw_placed(placed)
    rg_mix_nothing
    @rg_last_drawn[placed.sprite] = [placed.x, placed.y]
  end
end

# Which of a row of +count+ things the number +said+ names, read the way the interpreter reads a
# Ruby array: a number below nought counts back from the last. RG_NO_PLACE when it still names
# none, which is where the interpreter stops with an error.
def rg_place_named(said, count)
  place = said < 0 ? said + count : said
  place >= 0 && place < count ? place : RG_NO_PLACE
end

# Reference#names_in_draw_order: the sprite of a run that the order list names next.
def rg_place_in_ordered_run(said, count)
  place = rg_place_named(said, count)
  rg_fault("a draw order names sprite #{said} of the #{count} it puts in order") if place == RG_NO_PLACE
  place
end

# Reference#collision_sprite: the picture a sprite is showing.
def rg_pose_image(poses, count, pose)
  place = rg_place_named(pose, count)
  rg_fault("a sprite is showing picture #{pose} of its #{count}") if place == RG_NO_PLACE
  poses[place]
end

# Reference#pixels_overlap?: do two sprites' drawn pixels touch? Only the rectangle where the two
# boxes overlap is walked.
def rg_pixels_overlap(a_image, a_x, a_y, b_image, b_x, b_y)
  a_art, a_start, a_width, a_height = rg_picture_of(a_image)
  b_art, b_start, b_width, b_height = rg_picture_of(b_image)
  left = a_x > b_x ? a_x : b_x
  top = a_y > b_y ? a_y : b_y
  right = [a_x + a_width, b_x + b_width].min
  bottom = [a_y + a_height, b_y + b_height].min
  (top...bottom).each do |y|
    (left...right).each do |x|
      next if a_art[a_start + ((y - a_y) * a_width) + (x - a_x)] == RG_NOT_DRAWN
      return 1 if b_art[b_start + ((y - b_y) * b_width) + (x - b_x)] != RG_NOT_DRAWN
    end
  end
  0
end


# --- a sprite in blocks (Reference::SpriteBlocks, which holds the rule and says why) ---
#
# The blocks are fixed to the screen, as a background's are. What differs is where a block takes
# its color from, because a sprite is a small box and a block need not start inside it.

# SpriteBlocks#block_start and #round_up: where the block a column or row is in starts, and the end
# of the block an edge falls in.
def rg_block_start(at) = at - (at % @rg_sprite_block)
def rg_block_end(edge) = -((-edge) / @rg_sprite_block) * @rg_sprite_block

# Reference#picture_reader: what a picture shows at a column and row of itself, or RG_NOT_DRAWN
# where it is see-through and anywhere outside it.
def rg_picture_color(picture, col, row)
  art, start, width, height = picture
  return RG_NOT_DRAWN if col < 0 || col >= width || row < 0 || row >= height

  art[start + (row * width) + col]
end

# SpriteBlocks#paint_box: one box of a sprite whose picture's corner is at (x, y), the box's own
# corner at (left, top) on the screen. A block that starts left of the box or above it shows the
# box's first column or row; the last block across is drawn whole, past the box's right edge;
# nothing is drawn past its bottom edge.
def rg_paint_box_in_blocks(picture, x, y, left, top, width, height)
  first_row = top > 0 ? top : 0
  past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT
  first_col = left > 0 ? left : 0
  past_col = rg_block_end(left + width)
  past_col = RG_SCREEN_WIDTH if past_col > RG_SCREEN_WIDTH
  (first_row...past_row).each do |py|
    from_y = rg_clamp_wide(rg_block_start(py), top, top + height - 1)
    (first_col...past_col).each do |px|
      color = rg_picture_color(picture, rg_clamp_wide(rg_block_start(px), left, left + width - 1) - x, from_y - y)
      rg_set_pixel(px, py, color) if color != RG_NOT_DRAWN
    end
  end
end

# SpriteBlocks#paint_upright: a sprite that stands upright, a box at a time, back to front, so where
# one box's last block runs over the next the one in front wins. The boxes are the ones listed for
# the picture it shows (@rg_game_sprite_boxes).
def rg_paint_upright_in_blocks(placed)
  listed = @rg_game_sprite_blocks[placed.sprite]
  pictures = @rg_game_sprite_boxes[listed]
  listed += 1
  showing = @rg_game_image_pictures[placed.image]
  pictures.times do
    name = @rg_game_sprite_boxes[listed]
    boxes = @rg_game_sprite_boxes[listed + 1]
    box = listed + 2
    listed = box + (4 * boxes)
    next if name != showing

    picture = rg_picture_of(placed.image)
    (boxes - 1).downto(0) do |b|
      at = box + (4 * b)
      rg_paint_box_in_blocks(picture, placed.x, placed.y, placed.x + @rg_game_sprite_boxes[at],
                             placed.y + @rg_game_sprite_boxes[at + 1], @rg_game_sprite_boxes[at + 2],
                             @rg_game_sprite_boxes[at + 3])
    end
    return
  end
  rg_fault("sprite #{placed.sprite} is shown in blocks and has no boxes for the picture it shows")
end

# SpriteBlocks#turned_row: the row of its box a turned sprite shows on screen row +py+, which is the
# row at the top of the block, held to the box's first row when the block began above it, worked
# out as the display counts, in lines that come round.
def rg_turned_row(py, top, height)
  first = top % RG_TURNED_BOX_LINES
  past = first + height
  line = rg_block_start(py)
  line = first if line < first && first < RG_SCREEN_HEIGHT
  line = past - 1 if line >= past % RG_TURNED_BOX_LINES
  (line - first) % RG_TURNED_BOX_LINES
end

# SpriteBlocks#paint_turned: a sprite that turns or resizes, drawn in a box twice its picture's size
# about the picture's middle. A block that starts left of the box shows what the turned picture
# would show ONE COLUMN before the box begins; one that starts above it shows the box's first row;
# and the last block across is drawn whole.
def rg_paint_turned_in_blocks(placed)
  picture = rg_picture_of(placed.image)
  width = picture[2]
  height = picture[3]
  one_th = @rg_game_turn_rules[1]
  turn_cos, turn_sin = rg_affine_matrix(placed.angle % 360, placed.size)
  left = placed.x - (width / 2)
  top = placed.y - (height / 2)
  first_col = left > 0 ? left : 0
  past_col = rg_block_end(left + (width * 2))
  past_col = RG_SCREEN_WIDTH if past_col > RG_SCREEN_WIDTH
  return unless rg_turned_box_on_screen?(top, width, height, placed.resizes)

  (height * 2).times do |iy|
    py = rg_turned_box_line(top, iy)
    next if py < 0

    dy = rg_turned_row(py, top, height * 2) - height
    (first_col...past_col).each do |px|
      start = rg_block_start(px)
      dx = (start >= left ? start : left - 1) - left - width
      color = rg_picture_color(picture, (((turn_cos * dx) + (turn_sin * dy)) / one_th) + (width / 2),
                               (((-turn_sin * dx) + (turn_cos * dy)) / one_th) + (height / 2))
      rg_set_pixel(px, py, color) if color != RG_NOT_DRAWN
    end
  end
end

# Reference#paint_snapshot_object: one of the sprites kept for a rebuild is drawn in blocks while the
# picture is shown in them (rg_hook_block_size), unless the game leaves it as drawn.
def rg_paint_kept_sprite(placed)
  block = rg_hook_block_size
  if block == 1 || @rg_game_sprite_blocks[placed.sprite] == RG_NOT_IN_BLOCKS
    rg_draw_placed(placed)
    return
  end

  @rg_sprite_block = block
  if placed.turned
    rg_paint_turned_in_blocks(placed)
  else
    rg_paint_upright_in_blocks(placed)
  end
end

# --- the hooks it takes ---

# Reference#repaint_view, for sprites: the sprites kept for the rebuild that sit at this level, drawn
# after the level's scenery (this feature comes after the tiled one), each mixed and faded as its
# layer is.
def rg_sprites_paint_level(level)
  @rg_sprite_layer.each do |placed|
    next if placed.level != level

    rg_mix_as_sprite(placed.sprite)
    rg_fade_unless_left_as_drawn(@rg_game_sprite_fade_places[placed.sprite])
    rg_paint_kept_sprite(placed)
  end
end

# Reference#exec_screen: what was under each sprite went with the old screen, so nothing is put back
# over the new one. A console that places its sprites at the end of a pass takes them off after this.
def rg_sprites_screen_crossed(_new_kind)
  @rg_last_drawn.fill(nil)
  @rg_over_picture = nil
end

# Reference#sprites: what the game last put on screen, which stays as it was put from rg_objects_end
# until the next rg_objects_begin: how many, and each by its place among them as
# [whose it is, which picture it shows, x, y].
def rg_sprites_drawn_count = @rg_drawing.length

def rg_sprites_drawn_sprite(place)
  placed = @rg_drawing[place]
  [@rg_game_sprite_names[placed.sprite], @rg_game_image_pictures[placed.image], placed.x, placed.y]
end

# Reference#redraw_sprites_over_arrived_scenery asks whether any sprite was kept when it was drawn.
def rg_sprites_any_sprite_kept = !@rg_sprite_layer.empty?

# Framebuffer#shown and #pixel, with sprites over a painted screen: the layer in front, a colour or
# nil for each cell, while any sprite is in it.
def rg_sprites_front_layer = @rg_over_picture

# --- the state image (rg_sprites.c says what each field holds) ---

RG_MOST_SLICES_LEFT_OUT = 16_384 # rg_sprites.c's MAX_LEFT_OUT
RG_STATE_NOTHING_IN_FRONT = 0x8000 # rg_screen.c's RG_NOTHING_IN_FRONT, which this runtime keeps as nil

# "sprites": how many were last put on screen and how many are kept for a rebuild, and whether
# the layer over a painted picture is up.
RgSpritesFields = Data.define(:drawn, :kept, :over_picture_up)

# "sprites.drawing" and "sprites.kept", one a sprite: its number, picture, place and level, its
# turn, and how many slices a crowded line leaves out of it, which follow in the field after.
RgPlacedSpriteFields = Data.define(:sprite, :image, :x, :y, :level, :turned, :angle, :size, :resizes, :cut_count)

# The cuts field, one a slice left out: the line, and the piece.
RgCutFields = Data.define(:line, :piece)

# "sprites.drawn_places", one for each sprite there is room for: whether it was last drawn straight
# onto the picture, and where.
RgDrawnSpriteFields = Data.define(:drawn, :x, :y)

def rg_placed_sprite_fields(placed)
  RgPlacedSpriteFields.new(sprite: placed.sprite, image: placed.image, x: placed.x, y: placed.y, level: placed.level,
                    turned: rg_state_flag(placed.turned), angle: placed.angle, size: placed.size,
                    resizes: rg_state_flag(placed.resizes), cut_count: placed.cuts ? placed.cuts.length : 0)
end

# The +count+ sprites of +placed+ as field +name+, and the slices left out of them as +cuts_name+;
# gives back the sprites read, or +placed+ when writing. +cuts_before+ slices were read already
# for the other list.
def rg_visit_placed_objects(name, cuts_name, placed, count, cuts_before)
  placed_fields = rg_state_records(name, placed.map { |p| rg_placed_sprite_fields(p) }, RgPlacedSpriteFields, count)
  placed_fields.each do |fields|
    next if fields.sprite.between?(0, RG_MAX_SPRITES - 1) && fields.cut_count >= 0 &&
            fields.image.between?(0, @rg_game_picture_sizes[RG_SIZE_IMAGES] - 1)

    rg_state_refuse_damaged("a sprite names a sprite or a picture the game does not have")
  end
  cut_total = placed_fields.sum(&:cut_count)
  rg_state_refuse_damaged("more slices of sprites are left out than can be") if cut_total > RG_MOST_SLICES_LEFT_OUT - cuts_before
  cuts = rg_state_records(cuts_name, placed.flat_map { |p| (p.cuts || []).map { |line, piece| RgCutFields.new(line, piece) } },
                          RgCutFields, cut_total)
  return placed unless rg_state_reading

  placed_fields.map do |fields|
    these = cuts.shift(fields.cut_count).map { |cut| [cut.line, cut.piece] }
    RgPlaced.new(fields.sprite, fields.image, fields.x, fields.y, fields.level, fields.turned != 0, fields.angle, fields.size,
                 fields.resizes, these.empty? ? nil : these)
  end
end

# rg_hook_visit_state (rg_sprites.c's rg_sprites_visit_state).
def rg_sprites_visit_state
  counts = rg_state_record("sprites", RgSpritesFields.new(drawn: @rg_drawing.length, kept: @rg_sprite_layer.length,
                                                         over_picture_up: rg_state_flag(!@rg_over_picture.nil?)))
  unless counts.drawn.between?(0, RG_MAX_SPRITES) && counts.kept.between?(0, RG_MAX_SPRITES)
    rg_state_refuse_damaged("more sprites are on screen than there is room for")
  end
  @rg_drawing = rg_visit_placed_objects("sprites.drawing", "sprites.drawing.cuts", @rg_drawing, counts.drawn, 0)
  drawing_cuts = @rg_drawing.sum { |p| p.cuts ? p.cuts.length : 0 }
  @rg_sprite_layer = rg_visit_placed_objects("sprites.kept", "sprites.kept.cuts", @rg_sprite_layer, counts.kept, drawing_cuts)

  drawn_fields = @rg_last_drawn.map { |spot| spot ? RgDrawnSpriteFields.new(1, *spot) : RgDrawnSpriteFields.new(0, 0, 0) }
  drawn_fields = rg_state_records("sprites.drawn_places", drawn_fields, RgDrawnSpriteFields, RG_MAX_SPRITES)
  @rg_last_drawn = drawn_fields.map { |fields| fields.drawn != 0 ? [fields.x, fields.y] : nil }

  front = @rg_over_picture&.map { |color| color || RG_STATE_NOTHING_IN_FRONT } ||
          Array.new(RG_SCREEN_CELLS, RG_STATE_NOTHING_IN_FRONT)
  front = rg_state_numbers("sprites.over_picture", front)
  @rg_over_picture = (front.map { |color| color == RG_STATE_NOTHING_IN_FRONT ? nil : color } if counts.over_picture_up != 0)
end
