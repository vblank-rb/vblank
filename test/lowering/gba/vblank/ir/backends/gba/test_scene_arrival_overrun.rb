# frozen_string_literal: true

require "test_helper"

# A SCENE WHOSE SETUP RUNS PAST THE GAP BETWEEN PICTURES, on the console. Putting a scene's
# backgrounds up sends their pictures and maps into video memory with the layers switched off, and
# the console goes on drawing while that happens. When the work is bigger than the gap, the layers
# come back on part way down the picture: rows above are the backdrop, rows below are the scene, and
# where the line falls depends on how many cycles the pass spent getting there. So two builds of
# one game that differ anywhere before it disagree on that picture, and the player sees a torn one.
#
# The layers and the sprites stay off for the picture after the setup, wherever it ended, and come
# on in the next gap (GBATEK, DISPCNT: a write takes effect from the line being drawn). The first
# picture is then the backdrop from top to bottom, whatever the timing, and the one after it is the
# scene, whole.
class TestSceneArrivalOverrun < Minitest::Test
  HANDED_OVER_AT = 4
  TITLE = (0...64).map { |at| at.even? ? :green : :blue }

  # Tile +n+: white then red at the start of every row, so a row the scene shows is never one
  # colour (and a row of the backdrop always is), and +n+ in binary in the rest, so no two tiles
  # are alike and none is kept once for several.
  def self.numbered_tile(n)
    (0...64).map do |at|
      column = at % 8
      next :white if column.zero?
      next :red if column == 1

      n[((at / 8) * 6) + column - 2].zero? ? :red : :white
    end
  end
  WIDE = 96 # a map wider than the console keeps, so the view of it is filled as the scene comes up

  # The line of the gap a late handover waits for before the scene takes over: near the gap's end
  # (line 227), so the setup after it runs into the picture however quick it is.
  LATE_LINE = 215

  # A title, then a scene of +layers+ backgrounds, each a map of +tile_count+ different tiles, wide
  # enough that the view of it is filled as the scene comes up. With +late+ the pass that hands over
  # spends the gap until LATE_LINE first (or until line +late+, a number), read off the console's
  # line counter. With +halts+ the scene stops the game on its first pass, as an end screen does, so
  # no wait for a frame follows it. With +bordered+ the game is laid out for the Game Boy Color's
  # screen, shown in the middle of the Advance's with a border of blue and yellow round it.
  # A picture of 64×64 for the sprites a scene has of its own, number +n+: every 8×8 square cyan
  # down its first column, so each row of it shows cyan, and its own number in cyan and magenta
  # in the rest, so no square is like another and none is kept once for several.
  def self.numbered_picture(n)
    (0...(64 * 64)).map do |at|
      x = at % 64
      y = at / 64
      next :cyan if (x % 8).zero?

      square = (n * 64) + ((y / 8) * 8) + (x / 8)
      square[((y % 8) + (x % 8)) % 12].zero? ? :magenta : :cyan
    end
  end
  OWN_SPRITES = 6 # a scene's own sprites, along the top: their pictures go up as it takes over
  OWN_SPRITE_ROWS = (0...64).freeze
  # The columns only the last of them covers: its picture is the last copied, so the last a copy
  # running into the picture reaches.
  LAST_OWN_COLUMNS = ((OWN_SPRITES * 32)...((OWN_SPRITES * 32) + 32)).freeze

  private def handed_over(layers:, tile_count:, late: false, halts: false, bordered: false, own_sprites: 0, shared: false)
    title_tile = TITLE
    side = WIDE
    handed_over_at = HANDED_OVER_AT
    late_line = late == true ? LATE_LINE : late
    b = bordered ? Builder.new(options: VBlank::Cartridge::Options.new(console: :gba, variant: :color_screen)) : Builder.new
    b.extend(VBlank::Builder::Debug)
    b.instance_eval do
      screen :tiled
      border("#" => :blue, "." => :yellow) { "#.\n.#\n" } if bordered
      tile_count.times { |n| image(:"stripe_#{n}", width: 8, height: 8, data: TestSceneArrivalOverrun.numbered_tile(n)) }
      tiles :stripes, (0...tile_count).to_h { |n| [n, :"stripe_#{n}"] }
      image(:title_tile, width: 8, height: 8, data: title_tile)
      tiles :title_tiles, { 0 => :title_tile }
      # A sprite over every scene: the first picture of a scene holds it off too, so a write to
      # the display that lands part way down that picture (a blend, a scroll) shows nowhere.
      image(:marker, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      sprite :marker, at: [100, 50], facing: { still: :marker }
      map = Array.new(side) { |row| Array.new(side) { |col| ((row * side) + col) % tile_count } }
      state = var :state, 0
      pass = var :pass, 0
      # With +shared+, a background every scene shows, declared outside them.
      background :shared, tiles: :stripes, map: Array.new(20) { |row| Array.new(30) { |col| (row + col) % tile_count } } if shared
      scene(:title) { background :title, tiles: :title_tiles, map: Array.new(20) { [0] * 30 } }
      own_sprites.times { |n| image(:"own_#{n}", width: 64, height: 64, data: TestSceneArrivalOverrun.numbered_picture(n)) }
      scene(:play) do
        layers.times { |layer| background :"layer_#{layer}", tiles: :stripes, map: map }
        own_sprites.times { |n| sprite :"own_#{n}", at: [n * 32, 0], facing: { still: :"own_#{n}" } }
        halt if halts
      end
      game_loop do
        pass += 1
        state = 1 if pass == handed_over_at && own_sprites.zero?
        if late && pass == handed_over_at
          line = read_scanline
          while line < late_line
            line = read_scanline
          end
        end
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        # With sprites of its own, the scene is picked a pass ahead, so the gap that starts the
        # pass it takes over on writes its sprites' rows before its setup sends their pictures.
        state = 1 if pass == handed_over_at - 1 && own_sprites.positive?
      end
    end
    b.finalize_program
    b.program
  end

  # Each picture from the handover on, as the rows of it that are one colour (the backdrop).
  private def backdrop_rows_from_handover(program)
    rom = assemble_rom(program, name: "OVERRUN")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    (1..(HANDED_OVER_AT + 4)).filter_map do
      reader.step
      next unless reader.var(:state) == 1

      picture = reader.frame_gba
      (0...160).select { |row| picture[row * 240, 240].uniq.one? }
    end
  end

  def test_the_first_picture_of_a_scene_that_overruns_the_gap_is_the_backdrop_whole
    pictures = backdrop_rows_from_handover(handed_over(layers: 3, tile_count: 900, late: true))

    torn = pictures.reject { |rows| rows.empty? || rows.length == 160 }
    assert_empty torn, "a picture shows the backdrop on some rows and the scene on others: #{pictures.map(&:length)}"
    assert_equal 160, pictures.first.length, "the first picture of the scene is the backdrop: #{pictures.map(&:length)}"
    assert_empty pictures.last, "the scene is up whole after: #{pictures.map(&:length)}"
  end

  # A GAME IN A BORDER KEEPS ITS BORDER through a held picture: the border is sprites, so a held
  # picture there keeps the sprites on. The top rows of the screen, all border, show its two colours
  # on every picture from the handover, the held first one too; the game's window in the middle is
  # the backdrop on that first picture.
  BORDER_ROWS = (0...8).freeze  # the Color's 144 rows sit 8 rows down the Advance's 160
  WINDOW = (40...200).freeze    # ...and its 160 columns 40 across

  def test_a_scene_in_a_border_that_overruns_the_gap_keeps_the_border_up
    rom = assemble_rom(handed_over(layers: 3, tile_count: 900, late: true, bordered: true), name: "OVERRUNB")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    pictures = (1..(HANDED_OVER_AT + 4)).filter_map do
      reader.step
      reader.frame_gba if reader.var(:state) == 1
    end
    bare = pictures.map { |picture| BORDER_ROWS.count { |row| picture[row * 240, 240].uniq.one? } }

    assert_equal [0], bare.uniq, "border rows showing one colour, on each picture from the handover: #{bare}"
    scenery_rows = (8...152).reject { |row| MARKER_ROWS.cover?(row) || picture_row_in_window(pictures.first, row).uniq.one? }
    assert_empty scenery_rows, "the game's window is the backdrop on the held first picture, but for its sprite"
  end

  # The rows the sprite stands on, in a border: its own 50 to 57, 8 rows down.
  MARKER_ROWS = (58..65).freeze

  private def picture_row_in_window(picture, row) = picture[(row * 240) + WINDOW.first, WINDOW.size]

  # The layers held off come on in the next gap whatever the game does then, a stop included.
  def test_a_scene_that_overruns_the_gap_and_stops_the_game_is_up_on_the_next_picture
    pictures = backdrop_rows_from_handover(handed_over(layers: 3, tile_count: 900, late: true, halts: true))

    assert_equal 160, pictures.first.length, "the first picture of the scene is the backdrop: #{pictures.map(&:length)}"
    assert_empty pictures[1], "the picture after shows the scene: #{pictures.map(&:length)}"
    assert_empty pictures.last, "and the scene stays up: #{pictures.map(&:length)}"
  end

  # TWO BUILDS A LITTLE APART IN TIMING SHOW THE SAME PICTURES. The same scene, its setup started a
  # line or two apart, as two builds of one game differ: where the setup runs into the picture each
  # time, every first picture is the backdrop whole, sprite and all; where it fits the gap each time,
  # every first picture is the scene. (Started so that it ends in the gap's last line one way and
  # the picture's first the other, the two differ: that edge is the console's.)
  OVERRUN_LINES = [215, 218, 221, 224, 227].freeze
  FITTING_LINES = [false, 190, 200, 210].freeze

  def test_setups_a_little_apart_that_run_into_the_picture_show_the_same_pictures
    seen = OVERRUN_LINES.to_h { |line| [line, backdrop_rows_from_handover(handed_over(layers: 3, tile_count: 900, late: line))] }

    assert_equal [seen.values.first], seen.values.uniq,
                 "the scene's pictures by the line its setup started on: #{seen.transform_values { |pictures| pictures.map(&:length) }}"
    assert_equal 160, seen.values.first.first.length, "the first picture is the backdrop: #{seen.values.first.map(&:length)}"
  end

  # A SCENE'S OWN SPRITE PICTURES GO UP AFTER ITS SCENERY, as it takes over. Where the pictures run
  # on into the picture, the sprites must not show there from the row the copy reached down: the
  # sprite is up whole on that picture, or not at all, whichever line the setup started on. Torn,
  # the line falls where the cycles put it, and two builds of one game a few instructions apart show
  # different pictures. A setup that fits the gap shows the sprite whole on the picture after it, as
  # the interpreter does; one that starts in the gap's last line runs into the picture, which is held.
  ART_START_LINES = [160, 180, 190, 200, 205, 210, 215, 220, 224, 227].freeze
  CYAN = Color.resolve(:cyan)

  def test_a_scenes_own_sprites_are_never_torn_on_its_first_picture
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 1))
  end

  # The same for a scene with no background of its own: nothing of its scenery is sent before its
  # sprite pictures. With +shared+ it shows a background declared outside every scene.
  def test_own_sprites_of_a_scene_without_scenery_are_never_torn_on_its_first_picture
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 0))
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 0, shared: true))
  end

  # The rows of the last of the scene's own sprites showing on its first picture, by the line its
  # setup started on.
  private def rows_shown_by_start_line(layers:, shared: false)
    ART_START_LINES.to_h do |line|
      game = handed_over(layers: layers, tile_count: 16, late: line, own_sprites: OWN_SPRITES, shared: shared)
      rom = assemble_rom(game, name: "OVERRUNS")
      reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
      first = (1..(HANDED_OVER_AT + 4)).lazy.filter_map do
        reader.step
        reader.frame_gba if reader.var(:pass) == HANDED_OVER_AT
      end.first
      [line, OWN_SPRITE_ROWS.count { |row| first[(row * 240) + LAST_OWN_COLUMNS.first, LAST_OWN_COLUMNS.size].include?(CYAN) }]
    end
  end

  private def assert_sprites_whole_or_held(rows)
    assert_equal OWN_SPRITE_ROWS.size, rows.fetch(ART_START_LINES.first), "a setup that fits the gap shows the sprite whole: #{rows}"
    assert_equal 0, rows.fetch(ART_START_LINES.last), "a setup run into the picture holds it whole: #{rows}"
    assert_empty rows.reject { |_, shown| [0, OWN_SPRITE_ROWS.size].include?(shown) },
                 "rows of the scene's own sprites showing on its first picture, by the line its setup started on: #{rows}"
  end

  def test_setups_a_little_apart_that_fit_the_gap_show_the_same_pictures
    seen = FITTING_LINES.to_h { |line| [line, backdrop_rows_from_handover(handed_over(layers: 1, tile_count: 16, late: line))] }

    assert_equal [seen.values.first], seen.values.uniq,
                 "the scene's pictures by the line its setup started on: #{seen.transform_values { |pictures| pictures.map(&:length) }}"
    assert_empty seen.values.first.first, "the first picture is the scene: #{seen.values.first.map(&:length)}"
  end
end
