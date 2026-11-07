# frozen_string_literal: true

# A STRETCHED COLUMN (Reference#exec_draw_column_at): one column of a picture painted at a height the
# game works out as it runs. Joined into the runtime's class after rg_screen.rb for a game that draws
# a column. rg_columns.c says how, rule for rule; this is that file written again, method for method.
#
# The screen never asks it anything: the game calls rg_screen_column.

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
