# frozen_string_literal: true

# THE PICTURE IN FLAT BLOCKS (Reference @block, Reference::SpriteBlocks): `pixelate`, joined into the
# runtime's class after rg_screen.rb for a game that pixelates. rg_pixelation.c says how, rule for
# rule; this is that file written again, method for method.

# How many pixels a block is each way, 1 being the picture as drawn; and the size a screen the game
# paints is read in (Framebuffer @block).
def rg_pixelation_setup
  @rg_block = 1
  @rg_read_block = 1
  @rg_shown_columns = Array.new(RG_SCREEN_WIDTH, 0)
end

# Reference#exec_pixelate. The size is read as the picture is next built, or as a painted screen
# is next read, so the picture is owed again only when the size is a different one.
def rg_screen_pixelate(size)
  held_to = rg_clamp_wide(size, 1, @rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK])
  return if held_to == @rg_block

  @rg_block = held_to
  if rg_painted_screen?
    @rg_read_block = @rg_block
  else
    rg_request_repaint
  end
end

# Reference#exec_screen: the size of a block outlasts the screen it was set on.
def rg_pixelation_screen_set
  @rg_read_block = rg_painted_screen? ? @rg_block : 1
end

# The size of the blocks scenery is painted in (Reference @block): the scenery puts itself into
# blocks of it (rg_tiled.rb's rg_paint_scenery_in_blocks, Reference#paint_scenery_in_blocks).
def rg_pixelation_scenery_block_size = @rg_block

# --- a sprite in blocks (Reference::SpriteBlocks, which holds the rule and says why) ---
#
# The blocks are fixed to the screen, as a background's are. What differs is where a block takes
# its color from, because a sprite is a small box and a block need not start inside it.

# SpriteBlocks#block_start and #round_up: where the block a column or row is in starts, and the end
# of the block an edge falls in.
def rg_block_start(at) = at - (at % @rg_block)
def rg_block_end(edge) = -((-edge) / @rg_block) * @rg_block

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

# Reference#paint_snapshot_object: a sprite kept for a rebuild is drawn in blocks while the picture
# is shown in them, unless the game leaves it as drawn. Whether it was.
def rg_pixelation_paint_kept_sprite(placed)
  return false if @rg_block == 1 || @rg_game_sprite_blocks[placed.sprite] == RG_NOT_IN_BLOCKS

  if placed.turned
    rg_paint_turned_in_blocks(placed)
  else
    rg_paint_upright_in_blocks(placed)
  end
  true
end

# --- a painted screen read in blocks ---

# Framebuffer#shown: a painted screen in blocks of one is read as it is.
def rg_pixelation_shown_plain = @rg_read_block == 1

# Framebuffer#block_corner: the screen column whose color each column shows while a painted screen
# is read in blocks, which is the first of its block. Across, the blocks are fixed to the screen
# while the picture covers the row from its first column; when the window has been moved off the
# picture's left edge the first block of a row starts where the picture does. Worked out once for
# every column each time the picture is read; nil in blocks of one.
def rg_pixelation_shown_columns
  block = @rg_read_block
  return nil if block == 1

  first = @rg_camera_x < 0 ? -@rg_camera_x : 0
  columns = @rg_shown_columns
  RG_SCREEN_WIDTH.times { |x| columns[x] = x >= first ? first + (((x - first) / block) * block) : x }
  columns
end

# Framebuffer#pixel: down, every row of a block shows the block's top row.
def rg_pixelation_shown_row(y) = y - (y % @rg_read_block)
