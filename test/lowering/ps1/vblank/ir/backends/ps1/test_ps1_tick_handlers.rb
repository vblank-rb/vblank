# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Tick handlers on the PlayStation's tear-free screen, read where the checked run does not look.
#
# A HANDLER ON A TEAR-FREE SCREEN draws on the page still on the screen until the blank
# (Runtime::Frame#emit_ticks_on_next_page); the checked run reads only the page each pass drew, so the page on
# the screen is read here, from the emulator, after every frame, or held to the interpreter's first moment of
# each frame by the headless run. A handler waiting inside a repeat, on every console, is TestTimer's.
class TestPS1TickHandlers < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  RED = VBlank::Graphics::Color.resolve(:red)

  # A HANDLER THAT WAITS ON A TEAR-FREE SCREEN shows what it drew before its wait on the frame its wait ends,
  # over the page the game drew the pass before: a white bar as long as the passes the game had ended then.
  def test_a_handler_waiting_on_a_tear_free_screen_shows_its_drawing_where_the_interpreter_does
    program = program_of do
      screen :bitmap, tear_free: true
      waiting = var :waiting, 0
      passes = var :passes, 0
      beat = timer :beat, per_second: 20
      beat.on_tick do
        if waiting.zero?
          waiting = 1
          draw_rect_at 40, 40, 16, 16, :red
          wait_vblank
          waiting = 0
        end
      end
      game_loop do
        passes += 1
        clear_screen :blue
        draw_rect_at 0, 0, passes, 4, :white
      end
    end

    reads = %i[passes waiting]
    on_screen = ->(run) { [(0...40).count { |x| run.screen.pixel(x, 1) == VBlank::Graphics::Color.resolve(:white) }, run.screen.pixel(44, 44)] }
    interpreted = moments_on(Reference.new, program, reads, &on_screen)
    assert_includes interpreted.map { |_, read| read.last(2) }, [1, RED], "the handler's square over the first pass's bar"
    assert_equal interpreted, moments_on(PS1::HeadlessRun.new, program, reads, &on_screen)
  end

  # ...AND THE PASS'S OWN PAGE IS SHOWN FIRST, the handler's square never on it. The interpreter trades the
  # pages at the boundary and again at the handler's wait (Reference#advance_frame), so a frame of the pass's
  # page, blue, comes before each frame of the handler's, which holds its square. Drawn before the blank, the
  # square showed on the page on the screen, and the pass's page was never shown.
  def test_a_handler_waiting_on_a_tear_free_screen_shows_the_pass_page_first
    assert_equal [[0, 16 * 16]] * 5, red_on_screen_each_frame(waiting_handler_program, 11).drop(1).each_slice(2).to_a
  end

  # The same on a screen with a sprite over the picture, which is shown from a copy of each page.
  def test_a_handler_waiting_under_a_sprite_over_the_picture_shows_the_pass_page_first
    assert_equal [[0, 16 * 16]] * 5, red_on_screen_each_frame(waiting_handler_program(with_sprite: true), 11).drop(1).each_slice(2).to_a
  end

  # A HANDLER DRAWING MORE THAN A LIST HOLDS ON A TEAR-FREE SCREEN leaves the page on the screen alone: what it
  # draws goes on the page the next pass draws, whose clear covers it. Sent as the list filled, its squares
  # showed on the screen until the blank of every frame.
  def test_a_handler_drawing_much_on_a_tear_free_screen_leaves_the_page_on_screen_alone
    program = program_of do
      screen :bitmap, tear_free: true
      beat = timer :beat, per_second: 60
      beat.on_tick do
        repeat(150) { |i| draw_rect_at (i % 15) * 16, (i / 15) * 16, 8, 8, :red }
      end
      game_loop { clear_screen :blue }
    end

    assert_equal [0] * 12, red_on_screen_each_frame(program, 12)
  end

  private

  # A tear-free screen cleared blue every pass, whose handler draws a red square and waits on every tick it is
  # not already waiting in; +with_sprite+ puts a green sprite over the picture.
  def waiting_handler_program(with_sprite: false)
    program_of do
      screen :bitmap, tear_free: true
      if with_sprite
        image(:dot, "G" => :green) { "GGGG\nGGGG" }
        sprite :dot, at: [100, 100], over_picture: true
      end
      waiting = var :waiting, 0
      beat = timer :beat, per_second: 60
      beat.on_tick do
        if waiting.zero?
          waiting = 1
          draw_rect_at 0, 0, 16, 16, :red
          wait_vblank
          waiting = 0
        end
      end
      game_loop { clear_screen :blue }
    end
  end

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  # Each moment +run+ reports in 9 frames, the first of each frame alone: its frame, the variables +reads+,
  # and what the block reads off the screen.
  def moments_on(run, program, reads, &screen)
    seen = {}
    run.each_vblank { |frame| seen[frame] ||= [*reads.map { |name| run[name] }, *screen&.call(run)] }
    run.run(program, frames: 9)
    seen.to_a
  end

  # How many red pixels the page on the screen holds after each of +frames+ frames of the console.
  def red_on_screen_each_frame(program, frames)
    path = File.join(Dir.mktmpdir("ps1-ticks"), "ticks.exe")
    PS1.new.build(program, title: "TICKS").write(path)
    core = VBlank::Diagnostics::Emulator.open_ps1(path)
    Array.new(frames) do
      core.run_frame
      state = core.gpu_state
      core.colors_at(state.fetch(:display_x), state.fetch(:display_y), core.width, core.height).count(RED)
    end
  ensure
    core&.destroy
  end
end
