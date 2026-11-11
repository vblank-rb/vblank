# frozen_string_literal: true

require "shell_tests"

# A SHELL'S FIRST SCREEN MADE THE GAME'S OWN (`shell_screen`), shared by the tests of each runtime
# that plays one: the made-up port of ShellTests with a font, colours, a picture and words of its
# own on its first screen, and a line that shows a credits scene.
#
# THE ANSWER KEY is #first_screen_drawn_plainly: the same screen drawn by a plain game through the
# DSL, each word at a place worked out here from the rule the docs give (.claude/dsl/original.md,
# "The first screen"), in one state of the screen at a time. A shell's first screen is a VBlank
# program, so every runtime that plays it must show what this shows, pixel for pixel.
module ShellScreenTests
  include ShellTests

  # Every character the screen writes, each a 4x6 glyph worked out from its code, so no two are
  # alike and none is the built-in font's. The title's letters are ones the built-in font lacks.
  TITLE = "ÆØN"
  NEEDS = "LØAD ÆØN"
  LOAD_ROM = "LØAD RØM"
  SETTINGS = "SETTINGS"
  CREDITS = "CREDITS"
  CREDITS_PAGE = "ÆØN BY US"
  GLYPH_WIDTH = 4
  GLYPH_HEIGHT = 6
  GLYPHS = [TITLE, NEEDS, LOAD_ROM, SETTINGS, CREDITS, CREDITS_PAGE].join.chars.uniq.to_h do |char|
    bits = (char.ord * 2_654_435_761) >> 3
    rows = Array.new(GLYPH_HEIGHT) { |row| Array.new(GLYPH_WIDTH) { |column| char == " " ? 0 : (bits >> ((row * GLYPH_WIDTH) + column)) & 1 } }
    rows[0][0] = 1 unless char == " "
    [char, rows]
  end.freeze

  # The picture behind the words: two rows of four colours.
  SKY = %i[red green blue white yellow cyan magenta orange].freeze
  SKY_AT = [8, 4].freeze

  # The colours of each part of the screen, none of them the screen's own when a game gives none.
  COLORS = { title: :cyan, needs: :green, line: :blue, cursor: :red, chosen: :magenta, ground: :orange }.freeze

  # Where the rule puts each row of words on the Advance's screen in a font 6 rows tall: the lines
  # from the screen's middle down, a line and 5 rows apart; the line saying what the game needs two
  # such steps above the middle; the title its height and 9 rows above that.
  MIDDLE = 80
  LINE_STEP = GLYPH_HEIGHT + 5
  NEEDS_ROW = MIDDLE - (2 * LINE_STEP)
  TITLE_ROW = NEEDS_ROW - (GLYPH_HEIGHT + 9)
  CREDITS_ROW = 20

  # The screen's lines, top to bottom: the game's own goes under LOAD ROM.
  LINES = [LOAD_ROM, CREDITS, SETTINGS].freeze
  CREDITS_LINE = 1
  SETTINGS_LINE = 2

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # Fails saying how many pixels differ and where the first is, not with two whole pictures.
  private def assert_same_pixels(want, got, moment)
    refute_nil got, "no picture #{moment}"
    differing = want.each_index.reject { |at| want[at] == got[at] }
    first = differing.first

    assert_empty differing.first(1), "#{differing.size} pixels differ #{moment}, the first at column #{first && (first % 240)}, " \
                                     "row #{first && (first / 240)}: #{first && want[first]} was wanted and #{first && got[first]} is shown"
  end

  # The made-up port with a first screen of its own.
  private def styled_port(from, version: "1")
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: version) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      shell_screen do |first|
        font :runes, glyphs: GLYPHS
        image :sky, width: 4, height: 2, data: SKY
        first.font :runes
        first.title TITLE
        first.needs NEEDS
        first.labels load_rom: LOAD_ROM, settings: SETTINGS
        first.colors(**COLORS)
        first.picture :sky, at: SKY_AT
        first.line CREDITS, shows: :credits
        scene(:credits) { draw_text CREDITS_PAGE, :center, CREDITS_ROW, :white, font: :runes }
      end
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :wall_b, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        draw_rect_at heights[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 15
      end
    end
  end

  # The styled port as a shell is built from it.
  private def styled_port_without_copy(folder, version: "1") = styled_port(original_nowhere(folder), version: version)

  # THE ANSWER KEY: the styled port's first screen as a plain game draws it, standing still, with
  # the cursor on line +cursor+ (from 0), that line shown as chosen when +chosen+, or the credits
  # scene up in its place when +credits+.
  private def first_screen_drawn_plainly(cursor: 0, chosen: false, credits: false)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gba, for_computer: true))
    b.instance_eval do
      screen :bitmap
      font :runes, glyphs: GLYPHS
      image :sky, width: 4, height: 2, data: SKY
      game_loop do
        clear_screen COLORS[:ground]
        if credits
          draw_text CREDITS_PAGE, :center, CREDITS_ROW, :white, font: :runes
        else
          blit :sky, *SKY_AT
          draw_text TITLE, :center, TITLE_ROW, COLORS[:title], font: :runes
          draw_text NEEDS, :center, NEEDS_ROW, COLORS[:needs], font: :runes
          LINES.each_with_index do |words, place|
            color = if place != cursor then COLORS[:line]
                    else chosen ? COLORS[:chosen] : COLORS[:cursor]
                    end
            draw_text words, :center, MIDDLE + (LINE_STEP * place), color, font: :runes
          end
        end
      end
    end
    b.finalize_program
    b.program
  end

  # TODAY'S SCREEN, which a game that gives nothing must still show: the screen as VBlank drew it
  # before a game could change it, written out as a plain game standing still in one state.
  private def default_screen_drawn_plainly(cursor: 0, chosen: false)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gba, for_computer: true))
    b.instance_eval do
      screen :bitmap
      game_loop do
        clear_screen :black
        draw_text "MADE UP", :center, 40, :white
        draw_text "LOAD YOUR COPY OF THE GAME", :center, 56, :gray
        ["LOAD ROM", "SETTINGS"].each_with_index do |words, place|
          color = if place != cursor then :gray
                  else chosen ? :yellow : :white
                  end
          draw_text words, :center, 80 + (12 * place), color
        end
      end
    end
    b.finalize_program
    b.program
  end
end
