# frozen_string_literal: true

require "vblank"

# A game for a console whose build reads no buttons yet (DOS's): a block that drifts right a pixel a
# pass, so it is checked by what it draws and counts with nobody pressing anything.
Drift = VBlank.game "DRIFT", consoles: %i[gba dos] do
  screen :bitmap
  x = 40

  game_loop do
    x += 1
    clear_screen :black
    draw_rect_at x, 40, 8, 8, :yellow
  end
end

Drift.write_if_main
