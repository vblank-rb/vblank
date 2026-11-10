# frozen_string_literal: true

require "test_helper"

# THE STATE IMAGE OF THE C, JAVASCRIPT AND RUBY BUILDS (runtime/rg_state.h, Computer::StateFields):
# a game's whole state written at a frame boundary and read into a fresh run of the same build,
# which then plays on frame for frame as the unbroken run did. Kept once here and played by each of
# the three runs' own test file (test/lowering/{native,js,ruby}/), which says which build's
# windowless run plays it (#state_run) and which other builds' it reads a state across from
# (#other_runs): between them every pair of the three, both ways.
#
# The answer key is the same build's unbroken run, not the interpreter: a run read from a state
# starts at a pass the interpreter never reached by itself. Until the sound's half of the state is
# in, these games make no sound.
module StateImageTests
  STATE_AFTER = 40  # the frame the state is written after
  FRAMES_ON = 120   # how many frames the run read from it plays on
  SPEAKERS = %i[left right].freeze

  # A GAME OF EVERY KIND OF STATE THE IMAGE HOLDS SO FAR: variables, a list shifted round its ring,
  # random numbers, a timer and its handler, a press and a hold, a routine that waits for a frame
  # two calls deep, and save memory. It paints its whole picture every pass from those numbers, so
  # its picture says where it stands. It places its own waits (frame_sync: :manual), so the one in
  # spin is a frame of its own and not caught up with the loop's.
  private def state_game
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :bitmap
      best = save_var :best, 0
      x = var :x, 0
      spins = var :spins, 0
      beats = var :beats, 0
      trail = list :trail, capacity: 4, width: :byte
      beat = timer :beat, per_second: 25
      beat.on_tick { beats += 1 }
      func(:spin) do
        repeat(3) do
          wait_vblank
          spins += 1
        end
      end
      func(:spin_twice) { call :spin }
      game_loop do
        clear_screen :blue
        x += rand(1..3)
        x = 0 if x > 200
        trail.shift if trail.length == 4
        trail.push x
        best = x if x > best
        draw_rect_at x, 20, 8, 8, :white
        draw_rect_at beats % 200, 40, 8, 8, :red
        draw_rect_at spins % 200, 60, 8, 8, :green
        draw_rect_at trail[0], 80, 4, 4, :yellow
        draw_rect_at best, 100, 4, 4, :white if held(:b)
        call :spin_twice if pressed(:a)
        wait_vblank
      end
    end
    builder.finalize_program
    builder.program
  end

  # The buttons held on frame +frame+ counted from power-on: A pressed now and then, B held for a while.
  private def buttons_on(frame)
    [*(:a if (frame % 17).zero?), *(:b if (frame / 25).odd?)]
  end

  # Each frame's variables and the checks of its picture as stored and as shown (through the window,
  # a fade and the blocks), from the frame after +from+ on, watched as +run+ plays.
  private def frames_seen(run, program, frames:, from: 0)
    seen = []
    run.input_each_frame { |frame| buttons_on(from + frame) }
       .each_vblank do |_frame|
         pictures = [run.screen.to_a, run.screen.shown].map { |cells| VBlank::IR::Backends::RunComparison.picture_check(cells) }
         seen << [run.vars.dup, pictures]
       end
       .run(program, frames: frames)
    seen
  end

  # The unbroken run, frame by frame, and the state it wrote after STATE_AFTER.
  private def unbroken_with_state(program)
    run = state_run.writing_state_after(STATE_AFTER)
    [frames_seen(run, program, frames: STATE_AFTER + FRAMES_ON), run.state]
  end

  # Every frame's numbers and picture, from the first frame after the state came in.
  private def assert_plays_on_from(state, program, unbroken, reader: state_run, from: STATE_AFTER, frames: FRAMES_ON)
    resumed = frames_seen(reader.starting_from_state(state), program, frames: frames, from: from)
    resumed.each_with_index do |(vars, picture), k|
      assert_equal unbroken[from + k].first, vars, "frame #{from + k + 1}'s numbers read from the state differ from the unbroken run's"
      assert_equal unbroken[from + k].last, picture, "frame #{from + k + 1}'s picture differs from the unbroken run's"
    end
  end

  # A GAME WHOSE PICTURE IS ITS HISTORY: it never clears, so each pass's square stays on the page it
  # was drawn on, and only the state's copy of the pages can bring the picture back. On a tear-free
  # screen the squares fall on the two pages turn about. The window onto the picture moves too, a
  # square is drawn held inside an area that a frame ends within, and a sprite walks over the
  # squares, putting back the patch it covered each time it moves.
  private def kept_picture_game(tear_free:)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :bitmap, tear_free: tear_free
      image(:block, "#" => :green) { "####\n####\n####\n####" }
      x = var :x, 0
      walker = sprite :block, at: [0, 30]
      game_loop do
        x += rand(1..9)
        x = 0 if x > 220
        draw_rect_at x, (x * 7) % 140, 3, 3, :white
        draw_rect_at (x * 5) % 220, 31, 2, 2, :yellow
        walker.x = (x * 3) % 220
        camera x % 5, 0
        inside(0, 0, 120, 80) do
          draw_rect_at x, x % 70, 2, 2, :red
          wait_vblank
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  [false, true].each do |tear_free|
    define_method(:"test_a_kept_picture_comes_back_from_the_state#{"_on_two_pages" if tear_free}") do
      program = kept_picture_game(tear_free: tear_free)
      unbroken, state = unbroken_with_state(program)

      assert_operator unbroken.map(&:last).uniq.length, :>, 20, "the game's picture moves"
      assert_plays_on_from(state, program, unbroken)
      other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
    end
  end

  # A GAME WITH A FADE, A TINT AND BLOCKS UNDER WAY: each is set only now and then, so for many
  # frames after the state the picture shows one the game set before it, which only the state's
  # copy of the drawing features brings back.
  private def effects_game(tear_free:)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :bitmap, tear_free: tear_free
      n = var :n, 0
      x = var :x, 0
      level = var :level, 0
      size = var :size, 1
      game_loop do
        n += 1
        x += rand(1..5)
        x = 0 if x > 200
        level = (n * 3) % 90
        size = ((n / 13) % 6) + 1
        clear_screen :blue
        draw_rect_at x, 40, 30, 30, :white
        draw_rect_at 0, 0, 4, 4, :red
        draw_rect_at 4, 0, 4, 4, :green
        fade :black, level, inside: [0, 0, 120, 80] if n % 32 == 7
        tint :red, level if n % 32 == 23
        pixelate size if n % 13 == 0
        wait_vblank
      end
    end
    builder.finalize_program
    builder.program
  end

  [false, true].each do |tear_free|
    define_method(:"test_a_fade_and_blocks_under_way_come_back_from_the_state#{"_on_two_pages" if tear_free}") do
      program = effects_game(tear_free: tear_free)
      unbroken, state = unbroken_with_state(program)

      # After STATE_AFTER the fade held to a rectangle and blocks of 4 are in force.
      assert_plays_on_from(state, program, unbroken)
      other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
      # After frame 30 a tint is, set on frame 23.
      tinted = state_run.writing_state_after(30)
      frames_seen(tinted, program, frames: 31)
      [state_run, *other_runs].each { |reader| assert_plays_on_from(tinted.state, program, unbroken, reader: reader, from: 30, frames: 20) }
      assert_runtime_fields(state, VBlank::IR::Backends::Computer::StateFields.kept(save_memory: false, features: %i[fades pixelation]))
    end
  end

  # A GAME OF SCENERY DRAWN FROM TILES: a field scrolled only now and then, shown from its second
  # map since frame 25 and changed a cell at a time since, so after the state the picture shows a
  # scroll, a map and cells the game set before it. On the Advance a second background is held to a
  # box that moves now and then, in front of the field, bent row by row, and see-through by an
  # amount the game changes now and then; and a fade now and then is placed under it.
  private def scenery_game
    tile = Minitest::Test::SOLID_TILE
    boxed = game_console == :gba
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :tiled
      image(:red_t, "#" => :red) { tile }
      image(:blue_t, "#" => :blue) { tile }
      image(:white_t, "#" => :white) { tile }
      tiles :set, "#" => :red_t, "." => :blue_t, "o" => :white_t
      checks = Array.new(32) { |row| Array.new(32) { |col| (row + col).odd? ? "#" : "." }.join }
      stripes = Array.new(32) { |row| (row.even? ? "o" : ".") * 32 }
      field = background :field, tiles: :set, map: { checks: checks, stripes: stripes }
      n = var :n, 0
      x = var :x, 0
      haze = var :haze, 30
      if boxed
        layers :fog
        sky = nil
        layer(:fog, transparency: haze) { sky = background :sky, tiles: :set, map: Array.new(32) { "o#" * 16 } }
        sky.scroll_each_row { |row| (row + n) % 16 }
      end
      game_loop do
        n += 1
        x += rand(1..5)
        field.scroll_to x, n * 2 if n % 9 == 4
        field.show_map 1 if n == 25
        field.set_tile n % 32, (n / 32) % 32, "o" if n % 3 == 0
        if boxed
          sky.show_only_inside n % 100, 10, 60, 40 if n % 11 == 5
          haze = 20 + ((n * 7) % 60) if n % 10 == 3
          fade :black, (n * 3) % 90, under: :fog if n % 32 == 7
        end
        wait_vblank
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_scenery_scrolled_and_changed_comes_back_from_the_state
    program = scenery_game
    unbroken, state = unbroken_with_state(program)

    assert_operator unbroken.map(&:last).uniq.length, :>, 20, "the game's picture moves"
    assert_plays_on_from(state, program, unbroken)
    other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
    features = game_console == :gba ? %i[fades tiled] : %i[tiled]
    assert_runtime_fields(state, VBlank::IR::Backends::Computer::StateFields.kept(save_memory: false, features: features))
  end

  # A GAME OF THE RARER SCENERY: a wall told now and then to draw with other colours, whose cells
  # the game changes held together (`held: true`), under a status bar that moves now and then and
  # covers the ship for a while. Each pass waits five frames, so the state, taken in the middle of
  # one, holds what the pass set before it.
  private def rare_scenery_game
    tile = Minitest::Test::SOLID_TILE
    halves = Array.new(64) { |i| (i % 8) < 4 ? :red : :green }
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :tiled
      image :bars, width: 8, height: 8, data: halves, colors: %i[transparent red green]
      image :plain, width: 8, height: 8, data: Array.new(64, :green), colors: %i[transparent red green]
      colors :shimmer, %i[transparent yellow white]
      colors :dusk, %i[transparent blue white]
      image(:green_t, "#" => :green) { tile }
      image(:white_t, "#" => :white) { tile }
      tiles :wall, "#" => :bars, "." => :plain
      tiles :bar_tiles, "#" => :green_t, "o" => :white_t
      rays = background :rays, tiles: :wall, map: Array.new(32) { "#" * 32 }, held: true
      bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "o" * 32], top: screen_height - 16
      ship = sprite :white_t, at: [100, screen_height - 20]
      n = var :n, 0
      game_loop do
        n += 1
        ship.x = (n * 3) % 200
        rays.draw_with %i[shimmer dusk], showing: n % 3 if n % 5 == 2
        rays.set_tile n % 30, (n / 30) % 20, "." if n % 2 == 1
        rays.set_tile n % 30, (n / 30) % 20, "#" if n % 2 == 0
        bar.move_to screen_height - 16 - (n % 24) if n % 8 == 3
        bar.covers_sprites = true if n % 16 == 4
        bar.covers_sprites = false if n % 16 == 12
        repeat(5) { wait_vblank }
      end
    end
    builder.finalize_program
    builder.program
  end

  # A BACKGROUND THAT TURNS now and then, on a screen that turns its scenery. The game hands its
  # turn over again every frame, so this shows the turned picture comes back, not that the state's
  # copy of the turn is needed.
  private def turned_scenery_game
    tile = Minitest::Test::SOLID_TILE
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :rotozoom
      image(:red_t, "#" => :red) { tile }
      image(:white_t, "#" => :white) { tile }
      tiles :t, "#" => :red_t, "." => :white_t
      board = background :board, tiles: :t, map: Array.new(32) { |row| Array.new(32) { |col| (row + col).odd? ? "#" : "." }.join }
      n = var :n, 0
      game_loop do
        n += 1
        board.rotate(n * 7) if n % 6 == 1
        repeat(5) { wait_vblank }
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_recoloured_held_and_status_bar_scenery_comes_back_from_the_state
    programs = [rare_scenery_game]
    programs << turned_scenery_game if game_console == :gba
    programs.each do |program|
      unbroken, state = unbroken_with_state(program)

      assert_operator unbroken.map(&:last).uniq.length, :>, 5, "the game's picture moves"
      assert_plays_on_from(state, program, unbroken)
      other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
    end
  end

  # A GAME OF SPRITES THE FRAMEWORK DRAWS over scenery: a row of a dozen that crowds one line of
  # the screen, which a console that draws only so many on a line leaves some of out, a ship, and a
  # badge whose picture the game paints from a list. Each pass places them once and then waits seven
  # frames while the water scrolls, so the frames after the state, the middle of a pass, show the
  # sprites and the badge's picture as the pass left them.
  private def sprites_game
    tile = Minitest::Test::SOLID_TILE
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :tiled
      image(:sea_t, "#" => :blue) { tile }
      image(:ship, "#" => :white) { tile }
      image(:buoy, "#" => :red) { tile }
      tiles :sea, "#" => :sea_t
      water = background :water, tiles: :sea, map: Array.new(32) { "#" * 32 }
      colors :ink, %i[transparent white yellow]
      canvas = list :canvas, capacity: 32, width: :byte, full_of: 0
      badge = image :badge, from: canvas, width: 8, height: 8, colors: :ink
      sprite :badge, at: [100, 120]
      ship = sprite :ship, at: [10, 100]
      buoys = Array.new(12) { |i| sprite :buoy, at: [i * 12, 40] }
      n = var :n, 0
      game_loop do
        n += 1
        ship.x = (n * 5) % 200
        buoys[3].y = 40 + (n % 3)
        canvas[n % 32] = (n % 3) * 0x11
        badge.changed if n % 4 == 1
        repeat(7) do
          water.scroll_by 1, 0
          wait_vblank
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_sprites_the_framework_draws_come_back_from_the_state
    program = sprites_game
    unbroken, state = unbroken_with_state(program)

    assert_operator unbroken.map(&:last).uniq.length, :>, 10, "the game's picture moves"
    assert_plays_on_from(state, program, unbroken)
    other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
    assert_runtime_fields(state, VBlank::IR::Backends::Computer::StateFields.kept(save_memory: false, features: %i[tiled sprites]))
  end

  # A GAME THAT SOUNDS: a song on all four voices coming round, its volume turned down and faded,
  # a beep that fades on the second voice, a hit on the noise voice, and, on a console that mixes
  # recordings, a recording that loops and one that plays once. Mid-note, mid-fade and mid-recording
  # at the state.
  private def sounding_game
    mixes = VBlank::Console.described(game_console).recordings_at_once.positive?
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console, frame_sync: :manual))
    builder.instance_eval do
      screen :bitmap
      enable_sound
      song :tune do
        tempo 150
        voice(:melody) { duty :half; note :A4, :quarter; note :C5, :eighth; rest :eighth; note :E5, :quarter, slide_up: { every: 2, shift: 7 } }
        voice(:bass) { duty :eighth; volume 8; note :A3, :half; note :E3, :half }
        voice(:pad, plays: :wave) { note :A3, :half; note :C4, :half }
        voice(:drums, plays: :noise) { note :C3, :quarter; rest :quarter; note :C5, :quarter, pan: :left; rest :quarter }
      end
      if mixes
        boom = sample :boom, pcm: [0, 60, 0, -60] * 900, rate: 8000
        hum = sample :hum, pcm: [0, 30, 50, 30, 0, -30, -50, -30] * 50, rate: 16_000
      end
      n = var :n, 0
      play_song :tune
      game_loop do
        n += 1
        clear_screen :black
        draw_rect_at n % 200, 10, 4, 4, :white
        beep 990, duty: :eighth, decay: :slow if n % 23 == 9
        noise :explosion if n % 31 == 12
        music_volume 50 if n == 20
        fade_music_out frames: 30 if n == 30
        fade_music_in frames: 30 if n == 70
        if mixes
          hum.play(loop: true) if n == 8
          boom.play if n % 29 == 25
        end
        wait_vblank
      end
    end
    builder.finalize_program
    builder.program
  end

  # The sound a run makes: each speaker's samples, the mixer's slices and the sound log, as it
  # plays +frames+ frames.
  private def sound_heard(run, program, frames:)
    run.recording_sound.run(program, frames: frames)
    { left: run.sound, right: run.sound_right, mixed: run.mixed_sound }
  end

  def test_music_and_sound_under_way_come_back_from_the_state
    program = sounding_game
    unbroken_run = state_run.writing_state_after(STATE_AFTER)
    unbroken = sound_heard(unbroken_run, program, frames: STATE_AFTER + FRAMES_ON)
    refute unbroken[:left].all?(&:zero?), "the game makes sound"

    [state_run, *other_runs].each do |reader|
      resumed = sound_heard(reader.starting_from_state(unbroken_run.state), program, frames: FRAMES_ON)
      SPEAKERS.each do |side|
        heard = resumed[side]
        expected = unbroken[side].last(heard.length)
        first = heard.each_index.find { |i| heard[i] != expected[i] }
        assert_nil first, "the #{side} speaker after the state differs from the unbroken run's first at sample #{first} of #{heard.length}"
      end
      assert_equal unbroken[:mixed].last(resumed[:mixed].length), resumed[:mixed], "the mixer after the state differs"
    end
  end

  def test_a_run_read_from_a_state_plays_on_as_the_unbroken_run
    program = state_game
    unbroken, state = unbroken_with_state(program)

    assert_operator unbroken.map(&:last).uniq.length, :>, 20, "the game's picture moves"
    assert_plays_on_from(state, program, unbroken)
  end

  def test_a_state_read_into_a_run_waiting_two_calls_deep_carries_on_inside_them
    program = state_game
    seen = frames_seen(state_run, program, frames: STATE_AFTER + FRAMES_ON)
    # A frame on which spin counted and counts again on the next: the game is between two of spin's
    # waits there, inside spin, inside spin_twice.
    spins = seen.map { |vars, _| vars[:spins] }
    middle = (1...(spins.length - 1)).find { |k| spins[k] != spins[k - 1] && spins[k + 1] != spins[k] }
    refute_nil middle, "the game spins for several frames running"
    inside = state_run.writing_state_after(middle + 1)
    frames_seen(inside, program, frames: middle + 2)

    assert_plays_on_from(inside.state, program, seen, from: middle + 1, frames: 20)
  end

  def test_the_runtimes_fields_are_the_ones_every_runtime_keeps
    _, state = unbroken_with_state(state_game)

    assert_runtime_fields(state, VBlank::IR::Backends::Computer::StateFields.kept(save_memory: true))
  end

  # The runtime's fields in +state+ are +fields+, in order, each holding the numbers it says.
  private def assert_runtime_fields(state, fields)
    assert_equal fields.map(&:name), runtime_field_names(state)
    counts = state.lines.to_h { |line| [line.split("\t").first, line.split("\t").last.split.first.to_i] }
    fields.each do |field|
      assert_equal field.count, counts.fetch(field.name), "#{field.name} holds #{field.count} numbers" if field.count.is_a?(Integer)
    end
  end

  def test_a_state_from_another_build_of_the_game_reads_here
    program = state_game
    unbroken, = unbroken_with_state(program)
    other_runs.each do |other|
      run = other.writing_state_after(STATE_AFTER)
      frames_seen(run, program, frames: STATE_AFTER + 1)

      assert_plays_on_from(run.state, program, unbroken)
    end
  end

  def test_a_state_written_here_reads_in_another_build_of_the_game
    program = state_game
    unbroken, state = unbroken_with_state(program)
    other_runs.each { |other| assert_plays_on_from(state, program, unbroken, reader: other) }
  end

  # A small game with no save memory, of a variable that counts.
  private def counting_game
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: game_console))
    builder.instance_eval do
      screen :bitmap
      other_x = var :other_x, 0
      game_loop { other_x += 1 }
    end
    builder.finalize_program
    builder.program
  end

  def test_a_game_with_no_save_memory_keeps_no_save_fields
    run = state_run.writing_state_after(2)
    run.run(counting_game, frames: 3)
    runtime = runtime_field_names(run.state)

    assert_equal VBlank::IR::Backends::Computer::StateFields.kept(save_memory: false).map(&:name), runtime
  end

  # The names of the fields the runtime visits by hand, leaving out the ones the build writes.
  private def runtime_field_names(state)
    state.lines.map { |line| line.split("\t").first }.reject { |name| name.start_with?("game.", "list.", "patch.") }
  end

  def test_a_state_of_another_game_is_refused_naming_what_it_lacks
    _, state = unbroken_with_state(state_game)

    error = assert_raises(VBlank::IR::ProgramError) { state_run.starting_from_state(state).run(counting_game, frames: 3) }
    assert_match(/for another game/, error.message)
  end
end
