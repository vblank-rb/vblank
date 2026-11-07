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

# The size of the blocks scenery and sprites are painted in (Reference @block): each puts itself into
# blocks of it (rg_tiled.rb's rg_paint_scenery_in_blocks, Reference#paint_scenery_in_blocks;
# rg_sprites.rb's rg_paint_kept_sprite, Reference#paint_snapshot_object).
def rg_pixelation_block_size = @rg_block

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
