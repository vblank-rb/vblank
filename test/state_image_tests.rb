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
