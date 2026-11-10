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
# starts at a pass the interpreter never reached by itself. Until the screen's and the sound's
# halves of the state are in, these games paint their whole picture every pass and make no sound.
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

  # Each frame's variables and picture check, from the frame after +from+ on, watched as +run+ plays.
  private def frames_seen(run, program, frames:, from: 0)
    seen = []
    run.input_each_frame { |frame| buttons_on(from + frame) }
       .each_vblank { |_frame| seen << [run.vars.dup, VBlank::IR::Backends::RunComparison.picture_check(run.screen.to_a)] }
       .run(program, frames: frames)
    seen
  end

  # The unbroken run, frame by frame, and the state it wrote after STATE_AFTER.
  private def unbroken_with_state(program)
    run = state_run.writing_state_after(STATE_AFTER)
    [frames_seen(run, program, frames: STATE_AFTER + FRAMES_ON), run.state]
  end

  # Every frame's numbers are compared, and its picture from the first frame the game paints after
  # the state came in. The picture is not in the state yet, so until the game paints again it shows
  # what the run's own first pass painted.
  private def assert_plays_on_from(state, program, unbroken, reader: state_run, from: STATE_AFTER, frames: FRAMES_ON)
    resumed = frames_seen(reader.starting_from_state(state), program, frames: frames, from: from)
    painted = resumed.index { |_, picture| picture != resumed.first.last }
    refute_nil painted, "the game paints again after the state comes in"
    resumed.each_with_index do |(vars, picture), k|
      assert_equal unbroken[from + k].first, vars, "frame #{from + k + 1}'s numbers read from the state differ from the unbroken run's"
      assert_equal unbroken[from + k].last, picture, "frame #{from + k + 1}'s picture differs from the unbroken run's" if k >= painted
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
    runtime = state.lines.map { |line| line.split("\t").first }.reject { |name| name.start_with?("game.", "list.") }

    assert_equal VBlank::IR::Backends::Computer::StateFields.kept(save_memory: true).map(&:name), runtime
    counts = state.lines.to_h { |line| [line.split("\t").first, line.split("\t").last.split.first.to_i] }
    VBlank::IR::Backends::Computer::StateFields::FIELDS.each do |field|
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
    runtime = run.state.lines.map { |line| line.split("\t").first }.reject { |name| name.start_with?("game.", "list.") }

    assert_equal VBlank::IR::Backends::Computer::StateFields.kept(save_memory: false).map(&:name), runtime
  end

  def test_a_state_of_another_game_is_refused_naming_what_it_lacks
    _, state = unbroken_with_state(state_game)

    error = assert_raises(VBlank::IR::ProgramError) { state_run.starting_from_state(state).run(counting_game, frames: 3) }
    assert_match(/for another game/, error.message)
  end
end
