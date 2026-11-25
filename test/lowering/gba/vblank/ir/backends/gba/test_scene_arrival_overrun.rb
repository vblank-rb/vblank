# frozen_string_literal: true

require "test_helper"

# A scene whose setup runs past the gap between pictures, on the console. Putting a scene's
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
  OWN_SPRITES_BORDERED = 4 # ...in a border, whose sprite memory keeps room for its own pictures
  OWN_SPRITE_ROWS = (0...64).freeze
  # How far apart they stand, on the whole screen and in a border's smaller one.
  OWN_SPACING = 32
  OWN_SPACING_BORDERED = 16
  # Where a border puts the game's screen's corner on the console's (the Color's 160×144 in the
  # middle of the Advance's 240×160).
  BORDER_CORNER = [40, 8].freeze

  # A title, then a scene of +layers+ backgrounds, each a map of +tile_count+ different tiles, wide
  # enough that the view of it is filled as the scene comes up. With +late+ the pass that hands over
  # spends the gap until LATE_LINE first (or until line +late+, a number), read off the console's
  # line counter. With +halts+ the scene stops the game on its first pass, as an end screen does, so no wait for a frame
  # follows it. With +bordered+ the game is laid out for the Game Boy Color's screen, shown in the
  # middle of the Advance's with a border of blue and yellow round it. With +own_sprites+ the scene
  # has that many sprites of its own along the top. With +shared+ every scene shows a background
  # declared outside them, and with +title_scenery+ false the title has none of its own.
  # With +missed_gap+ the pass that hands over first runs on to line MISSED_GAP_LINE of the picture
  # after its gap, so it has missed the next gap's start by the time it reaches +late+.
  private def handed_over(layers:, tile_count:, late: false, halts: false, bordered: false, own_sprites: 0, shared: false,
                          title_scenery: true, missed_gap: false, painted: false)
    title_tile = TITLE
    side = WIDE
    handed_over_at = HANDED_OVER_AT
    late_line = late == true ? LATE_LINE : late
    spacing = bordered ? OWN_SPACING_BORDERED : OWN_SPACING
    b = bordered ? Builder.new(options: VBlank::Cartridge::Options.new(console: :gba, variant: :color_screen)) : Builder.new
    b.extend(VBlank::Builder::Debug)
    b.instance_eval do
      if painted
        screen :bitmap, tear_free: painted == :tear_free
      else
        screen :tiled
      end
      border("#" => :blue, "." => :yellow) { "#.\n.#\n" } if bordered
      tile_count.times { |n| image(:"stripe_#{n}", width: 8, height: 8, data: TestSceneArrivalOverrun.numbered_tile(n)) }
      tiles :stripes, (0...tile_count).to_h { |n| [n, :"stripe_#{n}"] }
      image(:title_tile, width: 8, height: 8, data: title_tile)
      tiles :title_tiles, { 0 => :title_tile }
      # A sprite over every scene: the first picture of a scene holds it off too, so a write to
      # the display that lands part way down that picture (a blend, a scroll) shows nowhere.
      image(:marker, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      if painted
        sprite :marker, at: [100, 50], facing: { still: :marker }, over_picture: true
      else
        sprite :marker, at: [100, 50], facing: { still: :marker }
      end
      map = Array.new(side) { |row| Array.new(side) { |col| ((row * side) + col) % tile_count } }
      state = var :state, 0
      pass = var :pass, 0
      # With +shared+, a background every scene shows, declared outside them.
      background :shared, tiles: :stripes, map: Array.new(20) { |row| Array.new(30) { |col| (row + col) % tile_count } } if shared
      scene(:title) { background :title, tiles: :title_tiles, map: Array.new(20) { [0] * 30 } if title_scenery && !painted }
      own_sprites.times { |n| image(:"own_#{n}", width: 64, height: 64, data: TestSceneArrivalOverrun.numbered_picture(n)) }
      scene(:play) do
        layers.times { |layer| background :"layer_#{layer}", tiles: :stripes, map: map }
        own_sprites.times do |n|
          if painted
            sprite :"own_#{n}", at: [n * spacing, 0], facing: { still: :"own_#{n}" }, over_picture: true
          else
            sprite :"own_#{n}", at: [n * spacing, 0], facing: { still: :"own_#{n}" }
          end
        end
        halt if halts
      end
      game_loop do
        pass += 1
        state = 1 if pass == handed_over_at && own_sprites.zero?
        if late && pass == handed_over_at
          if missed_gap
            line = read_scanline
            while line != TestSceneArrivalOverrun::MISSED_GAP_LINE
              line = read_scanline
            end
          end
          line = read_scanline
          while line < late_line
            line = read_scanline
          end
        end
        call({ 0 => :title, 1 => :play }, number: :state)
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

  # A game in a border keeps its border through a held picture: the border is sprites, so a held
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

  # Two builds a little apart in timing show the same pictures. The same scene, its setup started a
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

  # A scene's own sprite pictures go up after its scenery, as it takes over. Where the pictures run
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

  # A scene on a painted screen whose sprites are the console's own (`over_picture: true`): its
  # sprite pictures are copied as it takes over, as a tiled scene's are, so a copy that runs into
  # the picture must not show them torn either; on a tear-free screen too, whose page flip writes
  # the display's settings on every pass.
  def test_own_sprites_of_a_painted_scene_are_never_torn_on_its_first_picture
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 0, painted: true))
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 0, painted: :tear_free))
  end

  # A game with no backgrounds at all, whose scenes have only sprites: every scene the game picks is
  # still a screen of its own (IR::Stacking.every_scene), so it holds its layers as the others do.
  def test_own_sprites_in_a_game_that_sends_no_scenery_are_never_torn_on_their_first_picture
    assert_sprites_whole_or_held(rows_shown_by_start_line(layers: 0, title_scenery: false))
  end

  # A game in a border: its border is sprites, which stay up through a held picture, so a scene's
  # own sprites must be held some other way. The border's top rows show its colours on the first
  # picture whatever line the setup started on.
  def test_own_sprites_in_a_border_are_never_torn_on_their_first_picture
    rows = rows_shown_by_start_line(layers: 1, bordered: true)

    assert_sprites_whole_or_held(rows.transform_values(&:first))
    assert_equal [0], rows.values.map(&:last).uniq, "border rows showing one colour on the first picture: #{rows}"
  end

  # ...and where that scene stops the game on its first pass, its sprites come up on a picture
  # after the stop, as the layers do: no pass after it copies them in. In a plain build and in one
  # built to be checked against the interpreter, which stop the game in different places.
  def test_own_sprites_in_a_border_come_up_after_a_scene_that_stops_the_game
    game = handed_over(layers: 1, tile_count: 16, late: ART_START_LINES.last, halts: true,
                       own_sprites: OWN_SPRITES_BORDERED, bordered: true)
    left, top = BORDER_CORNER
    # The columns only the last sprite covers.
    first_column = left + ((OWN_SPRITES_BORDERED - 2) * OWN_SPACING_BORDERED) + 64
    shown = { plain: assemble_rom(game, name: "STOPPED"),
              checked: VBlank::Cartridge::AdvanceBuild.checked_cartridge_for(game, title: "STOPPED") }.transform_values do |rom|
      picture = VBlank::Diagnostics::Verifier.new(rom, frames: HANDED_OVER_AT + 6).frame_gba
      OWN_SPRITE_ROWS.count { |row| picture[((row + top) * 240) + first_column, OWN_SPACING_BORDERED].include?(CYAN) }
    end

    assert_equal({ plain: OWN_SPRITE_ROWS.size, checked: OWN_SPRITE_ROWS.size }, shown,
                 "rows of the scene's own sprite showing after the stop, by build")
  end

  # One hold for a scene's scenery and its sprite pictures. Switched on between the two and off
  # again, a line drawn in that moment shows the scene with the last scene's sprite pictures, at a
  # row set by timing. So the pictures add no switching off of their own: the display's layers go
  # off as often in a game whose scene sends them after its scenery as in one whose scene sends
  # scenery alone.
  def test_a_scenes_scenery_and_sprite_pictures_are_sent_under_one_hold
    with_sprites = layers_switched_off(handed_over(layers: 1, tile_count: 16, own_sprites: OWN_SPRITES))
    scenery_alone = layers_switched_off(handed_over(layers: 1, tile_count: 16))

    assert_operator scenery_alone, :>=, 1, "the layers went off for the scenery at least once"
    assert_equal scenery_alone, with_sprites, "times the layers went off, with the scene's own sprites and without"
  end

  # How many times the display's settings went from some layer on to none, from power-on until a
  # few passes after the handover.
  DISPLAY_CONTROL = 0x0400_0000
  LAYER_BITS = 0x1F00 # the four backgrounds and the sprites

  private def layers_switched_off(game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hold.gba")
      assemble_rom(game, name: "ONEHOLD").write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        probe.step(HANDED_OVER_AT + 4)
        on = probe.display_writes.select { |write| write.kind == :register && write.address == DISPLAY_CONTROL }
                  .map { |write| write.value.anybits?(LAYER_BITS) }
        on.each_cons(2).count { |before, after| before && !after }
      ensure
        probe.close
      end
    end
  end

  # The rows of the last of the scene's own sprites showing on its first picture, by the line its
  # setup started on; in a border, with how many of the border's top rows are one colour.
  private def rows_shown_by_start_line(bordered: false, **game)
    spacing = bordered ? OWN_SPACING_BORDERED : OWN_SPACING
    count = bordered ? OWN_SPRITES_BORDERED : OWN_SPRITES
    left, top = bordered ? BORDER_CORNER : [0, 0]
    # The columns only the last of them covers: its picture is the last copied, so the last a copy
    # running into the picture reaches.
    columns = ((((count - 2) * spacing) + 64 + left)...(((count - 1) * spacing) + 64 + left))
    ART_START_LINES.to_h do |line|
      first = first_picture(handed_over(tile_count: 16, late: line, own_sprites: count, bordered: bordered, **game))
      shown = OWN_SPRITE_ROWS.count { |row| first[((row + top) * 240) + columns.first, columns.size].include?(CYAN) }
      next [line, shown] unless bordered

      [line, [shown, BORDER_ROWS.count { |row| first[row * 240, 240].uniq.one? }]]
    end
  end

  # The picture shown after the pass the scene takes over on.
  private def first_picture(game)
    rom = assemble_rom(game, name: "OVERRUNS")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    (1..(HANDED_OVER_AT + 4)).lazy.filter_map do
      reader.step
      reader.frame_gba if reader.var(:pass) == HANDED_OVER_AT
    end.first
  end

  private def assert_sprites_whole_or_held(rows)
    assert_equal OWN_SPRITE_ROWS.size, rows.fetch(ART_START_LINES.first), "a setup that fits the gap shows the sprite whole: #{rows}"
    assert_equal 0, rows.fetch(ART_START_LINES.last), "a setup run into the picture holds it whole: #{rows}"
    assert_empty rows.reject { |_, shown| [0, OWN_SPRITE_ROWS.size].include?(shown) },
                 "rows of the scene's own sprites showing on its first picture, by the line its setup started on: #{rows}"
  end

  # A pass that has already missed a gap when its scene takes over is late, and the picture drawn
  # while it finishes is not one the interpreter has: the pass's own picture is the one after its
  # wait. So that late picture holds the scene off whether the setup ends in the gap or runs on past
  # it, and two builds of one game whose setups take different times show the same pictures from
  # power-on. Here the setup starts at lines spread over the gap, so it ends in the gap at the first
  # and runs into the picture at the last.
  MISSED_GAP_LINE = 100
  MISSED_GAP_START_LINES = [165, 190, 210, 227].freeze

  def test_a_late_pass_shows_its_scene_on_the_same_picture_wherever_its_setup_ends
    seen = MISSED_GAP_START_LINES.to_h do |line|
      [line, pictures_from_power_on(handed_over(layers: 1, tile_count: 16, own_sprites: OWN_SPRITES, late: line, missed_gap: true))]
    end

    assert_equal [seen.values.first], seen.values.uniq,
                 "the pictures from power-on by the line the late pass's setup started on: #{seen}"
    assert_includes seen.values.first.drop(1), 160, "the late picture, after power-on's, is the backdrop whole: #{seen.values.first}"
    assert_equal 0, seen.values.first.last, "the scene is up whole after: #{seen.values.first}"
  end

  # Each picture from power-on until a few after the handover, as the rows of it that are one colour.
  private def pictures_from_power_on(game)
    rom = assemble_rom(game, name: "LATEPASS")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    (1..(HANDED_OVER_AT + 6)).map do
      reader.step
      picture = reader.frame_gba
      (0...160).count { |row| picture[row * 240, 240].uniq.one? }
    end
  end

  # A pass that takes the scene over part way down a picture (the pass before ran long): switching
  # the layers off at once shows the last scene above the line the switch reached and the backdrop
  # below it. The sending waits for the gap instead, so that picture is the last scene whole, as the
  # interpreter shows it, and the picture after it is held as any late pass's is.
  MID_PICTURE_LINES = [40, 80, 120, 140, 159].freeze

  def test_a_scene_taken_over_part_way_down_a_picture_does_not_tear_that_picture
    seen = MID_PICTURE_LINES.to_h do |line|
      [line, pictures_from_power_on(handed_over(layers: 1, tile_count: 16, late: line, missed_gap: true))]
    end

    torn = seen.reject { |_, rows| rows.all? { |count| [0, 160].include?(count) } }
    assert_empty torn, "pictures from power-on, as the rows of each that are the backdrop, by the line the pass reached: #{seen}"
    assert_equal [seen.values.first], seen.values.uniq, "wherever down the picture it began: #{seen}"
  end

  # Two sendings in one pass, the first started late in the gap so it runs into the picture and
  # holds the layers off for the rest of it. The second finds them off already, so waiting for the
  # gap would save no picture from tearing; it would only spend the rest of the picture, and the
  # pass would end in the next gap and wait a whole picture more, the game a frame behind from
  # there. Two backgrounds walking into a new area in one gap are the same shape: a big set of
  # tiles brought in, then a small one.
  def test_a_second_sending_after_one_that_ran_into_the_picture_does_not_wait_for_the_gap
    rom = assemble_rom(taken_over_twice, name: "TWOSENDS")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    passes = (1..(HANDED_OVER_AT + 6)).map do
      reader.step
      reader.var(:pass)
    end

    lost = passes.each_cons(2).drop(1).reject { |before, after| after == before + 1 }
    assert_empty lost, "the pass count at each frame from power-on: #{passes}"
  end

  # A title, then on pass HANDED_OVER_AT, from LATE_LINE of the gap, scene :play and then scene
  # :sky, each with a background of its own to send: the first many tiles, the second one tile.
  private def taken_over_twice
    handed_over_at = HANDED_OVER_AT
    late_line = LATE_LINE
    b = Builder.new
    b.extend(VBlank::Builder::Debug)
    b.instance_eval do
      screen :tiled
      900.times { |n| image(:"stripe_#{n}", width: 8, height: 8, data: TestSceneArrivalOverrun.numbered_tile(n)) }
      tiles :stripes, (0...900).to_h { |n| [n, :"stripe_#{n}"] }
      image(:puff, "#" => :white, "." => :transparent) { (["##......"] + (["........"] * 7)).join("\n") }
      tiles :puffs, { 0 => :puff }
      image(:title_tile, width: 8, height: 8, data: TestSceneArrivalOverrun::TITLE)
      tiles :title_tiles, { 0 => :title_tile }
      map = Array.new(WIDE) { |row| Array.new(WIDE) { |col| ((row * WIDE) + col) % 900 } }
      state = var :state, 0
      then_state = var :then_state, 0
      pass = var :pass, 0
      scene(:title) { background :title, tiles: :title_tiles, map: Array.new(20) { [0] * 30 } }
      scene(:play) { background :ground, tiles: :stripes, map: map }
      scene(:sky) { background :clouds, tiles: :puffs, map: Array.new(20) { [0] * 30 } }
      game_loop do
        pass += 1
        then_state = 0
        if pass == handed_over_at
          line = read_scanline
          line = read_scanline while line < late_line
          state = 1
          then_state = 2
        end
        call({ 0 => :title, 1 => :play }, number: :state)
        call({ 2 => :sky }, number: :then_state)
      end
    end
    b.finalize_program
    b.program
  end

  # A scene whose sending can need more than the gap leaves it holds its first picture wherever the
  # sending ends: two builds of one game move its pictures from different memories at different
  # speeds, and one ending in the gap where the other runs a few lines on must not show a different
  # picture. Here a background of many tiles, its setup started where it fits the gap (with no wait,
  # and at line 190) and where it runs into the picture.
  BIG_SENDING_START_LINES = [false, 190, 215, 227].freeze

  def test_a_scene_whose_sending_can_pass_the_gap_holds_its_first_picture_wherever_it_ends
    seen = BIG_SENDING_START_LINES.to_h { |line| [line, backdrop_rows_from_handover(handed_over(layers: 1, tile_count: 900, late: line))] }

    assert_equal [seen.values.first], seen.values.uniq,
                 "the scene's pictures by the line its setup started on: #{seen.transform_values { |pictures| pictures.map(&:length) }}"
    assert_equal 160, seen.values.first.first.length, "the first picture is the backdrop: #{seen.values.first.map(&:length)}"
    assert_empty seen.values.first.last, "the scene is up whole after: #{seen.values.first.map(&:length)}"
  end

  def test_setups_a_little_apart_that_fit_the_gap_show_the_same_pictures
    seen = FITTING_LINES.to_h { |line| [line, backdrop_rows_from_handover(handed_over(layers: 1, tile_count: 16, late: line))] }

    assert_equal [seen.values.first], seen.values.uniq,
                 "the scene's pictures by the line its setup started on: #{seen.transform_values { |pictures| pictures.map(&:length) }}"
    assert_empty seen.values.first.first, "the first picture is the scene: #{seen.values.first.map(&:length)}"
  end
end
