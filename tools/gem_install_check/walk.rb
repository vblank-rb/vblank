# frozen_string_literal: true

require "vblank"

Walk = VBlank.game "WALK", consoles: %i[gba gbc snes] do
  screen :bitmap
  x = 40

  game_loop do
    x += 1 if held(:right)
    clear_screen :black
    draw_rect_at x, 40, 8, 8, :yellow
  end
end

Walk.write_if_main
