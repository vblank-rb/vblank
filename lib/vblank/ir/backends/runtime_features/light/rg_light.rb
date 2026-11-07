# frozen_string_literal: true

# A LIGHT (Framebuffer#shade_outside, Reference#work_out_shade): a `spotlight` or an `iris_out`, which
# darkens the picture everywhere outside one span of each row, as it is shown. Joined into the runtime's
# class after rg_screen.rb for a game that has a light. rg_light.c says how, rule for rule; this is
# that file written again, method for method.
#
# The screen never asks it about a pixel. It asks once a read for the colour table and the rows
# (rg_light_dim_filter) that the darkened part of the picture is read through.

# Each row's lit span, how many sixteenths the rest of the row is darkened by (nought darkens
# nothing), the row being asked about, and whether the scene that just ran has the light off.
def rg_light_setup
  @rg_shade_spans = Array.new(RG_SCREEN_HEIGHT) { [0, 0] }
  @rg_shade_steps = 0
  @rg_shade_row = 0
  @rg_shade_off = false
  # The filter handed to the screen: its rows say which pixels of each row are dark, and its table is
  # made again when the steps are not the ones it was made for (-1 for none yet).
  @rg_dim_rows = Array.new(RG_SCREEN_HEIGHT) { [0, 0, false] }
  @rg_dim_filter = RgShownFilter.new(nil, false, @rg_dim_rows, false)
  @rg_dim_table_steps = -1
end

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

# Framebuffer#lit?, row by row: is (x, y) inside its row's span? A span that comes round the edge
# (left past right) is lit outside [right, left), so the dark pixels are the ones within it; a span
# that does not is lit within [left, right), so the dark ones are outside it. A row is
# [from, to, inverted]: a pixel is dark when +inverted+ differs from from <= x < to.
def rg_light_fill_dim_rows
  RG_SCREEN_HEIGHT.times do |y|
    left, right = @rg_shade_spans[y]
    row = @rg_dim_rows[y]
    row[0] = left <= right ? left : right
    row[1] = left <= right ? right : left
    row[2] = left <= right
  end
end

# Reference#work_out_shade: every row's span from the game's own expressions, top to bottom, then
# the amount, then the rows the screen reads. The spans change nowhere else.
def rg_screen_work_out_shade
  RG_SCREEN_HEIGHT.times do |row|
    @rg_shade_row = row
    rg_game_shade_span
  end
  @rg_shade_row = RG_SCREEN_HEIGHT
  rg_game_shade_amount
  rg_light_fill_dim_rows
end

# Framebuffer#light_off=: whether the scene that just ran has the light switched off, set as the
# frame ends, before it is shown.
def rg_shade_switch(on)
  @rg_shade_off = on == 0
end

# rg_hook_dim_filter (Framebuffer#shade_outside, #lit?): nothing while no light darkens any of the
# picture, else the filter, its table made again when the steps are not the ones it was made for.
def rg_light_dim_filter
  return nil if @rg_shade_steps == 0 || @rg_shade_off

  filter = @rg_dim_filter
  if @rg_dim_table_steps != @rg_shade_steps
    steps = @rg_shade_steps
    filter.table = Hash.new { |table, color| table[color] = rg_darkened_by_display(color, steps) }
    @rg_dim_table_steps = steps
  end
  filter
end
