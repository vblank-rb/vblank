# frozen_string_literal: true

require "test_helper"
require "stringio"

# PICTURES ON A SUPER FX CARTRIDGE ARE PAINTED BY THE CHIP (Runtime::ChipBlit): blit, and text,
# which is pictures on a painted screen there. The console works out the rows and tiles the
# picture covers and the chip paints them; the picture is the interpreter's on every pass, and a
# picture costs the frame a small part of what the console's own processor took.
class TestSNESChipBlit < Minitest::Test
  BALL = ["..####..", ".######.", "########", "########", "########", "########", ".######.", "..####.."].join("\n")
  BOX = Array.new(16) { |r| (0...16).map { |c| (r + c).even? ? "#" : "+" }.join }.join("\n")
  WIDE = (["#.#" * 13] * 5).join("\n")

  # Pictures moving over the screen's edges and past them, at every place modulo eight, with
  # see-through pixels and without, inside an area, and text in a colour picked as the game runs.
  def self.edges
    VBlank.game("CHIP PICTURES", consoles: %i[snes]) do
      screen :bitmap
      image(:ball, "." => :transparent, "#" => :yellow) { TestSNESChipBlit::BALL }
      image(:box, "#" => :red, "+" => :blue) { TestSNESChipBlit::BOX }
      image(:wide, "#" => :green, "." => :transparent) { TestSNESChipBlit::WIDE }
      n = var :n, 0
      c = var :c, 0
      game_loop do
        clear_screen :cyan
        blit :ball, (n * 7) - 30, (n * 5) - 20
        blit :box, 250 - (n * 3), 220 - (n * 2)
        blit :wide, (n % 17) - 8, 100
        blit :box, -9, -9
        blit :box, 248, 216
        inside 33, 41, 70, 50 do
          blit :box, (n % 40) + 20, 30
          blit :wide, 30, (n % 30) + 30
          draw_text "HELLO", 25, 60, :white
        end
        draw_text "SCORE", 100, 130, %i[white red], showing: c
        draw_number n, 120, 140, :yellow, digits: 3
        c = 1 - c
        n += 1
      end
    end
  end

  # Three pictures moving across a screen cleared each pass.
  def self.three_pictures
    VBlank.game("CHIP THREE PICTURES", consoles: %i[snes]) do
      screen :bitmap
      image(:ball, "." => :transparent, "#" => :yellow) { TestSNESChipBlit::BALL }
      n = var :n, 0
      game_loop do
        clear_screen :black
        repeat(3) { |i| blit :ball, (i * 60) + (n & 7), 50 }
        n += 1
      end
    end
  end

  # Walls the chip draws in a routine of the game's (Runtime::ChipColumns) beside rectangles and
  # pictures the chip paints for the console in the same pass, each a program of its own in
  # another bank: the chip's quick memory kept or refilled as the bank changes, and the list of
  # tiles readied shared by all three.
  def self.walls_beside_pictures
    VBlank.game("CHIP WALLS PICTURES", consoles: %i[snes]) do
      screen :bitmap
      image(:ball, "." => :transparent, "#" => :yellow) { TestSNESChipBlit::BALL }
      image(:box, "#" => :red, "+" => :blue) { TestSNESChipBlit::BOX }
      n = var :n, 0
      func :walls, on_chip: true do
        repeat(20) { |col| draw_column_at :box, slice: col + n, x: (col * 3) + 60, top: 40 + (col & 7), height: 30 + col }
      end
      game_loop do
        clear_screen :black
        draw_rect_at (n % 30) + 50, 50, 40, 30, :green
        call :walls
        blit :ball, (n % 40) + 55, 60
        fill_rect 0, 0, 16, 8, :white
        call :walls
        blit mirror(:box), (n % 20) + 70, 100
        n += 1
      end
    end
  end

  # A routine run on the chip that paints nothing, between two rectangles and two pictures.
  def self.sums_between_paintings
    VBlank.game("CHIP SUMS PICTURES", consoles: %i[snes]) do
      screen :bitmap
      image(:ball, "." => :transparent, "#" => :yellow) { TestSNESChipBlit::BALL }
      n = var :n, 0
      total = var :total, 0
      func :sums, on_chip: true do
        repeat(8) { |i| total += i + n }
      end
      game_loop do
        clear_screen :blue
        draw_rect_at n % 50, 20, 24, 16, :red
        blit :ball, (n % 60) + 3, 40
        call :sums
        draw_rect_at (n % 50) + 5, 30, 24, 16, :green
        blit mirror(:ball), (n % 60) + 9, 44
        draw_number total & 255, 100, 100, :white, digits: 3
        n += 1
      end
    end
  end

  def test_walls_drawn_by_a_routine_on_the_chip_beside_pictures_are_the_interpreters
    game_player.run(self.class.walls_beside_pictures.program(console: :snes, variant: :superfx), frames: 30)
  end

  def test_a_routine_on_the_chip_between_paintings_leaves_them_the_interpreters
    game_player.run(self.class.sums_between_paintings.program(console: :snes, variant: :superfx), frames: 30)
  end

  private def lines_spare(game)
    rom = game.build_rom(console: :snes, variant: :superfx, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 20).fewest_lines_spare
  end

  def test_pictures_the_chip_paints_are_the_interpreters_on_every_pass
    game_player.run(self.class.edges.program(console: :snes, variant: :superfx), frames: 60)
  end

  # The bar sits between what the console's own processor left painting the three pictures and
  # what the chip leaves, so pictures painted on the console again fail it.
  def test_pictures_the_chip_paints_leave_room
    assert_operator lines_spare(self.class.three_pictures), :>=, 130
  end
end
