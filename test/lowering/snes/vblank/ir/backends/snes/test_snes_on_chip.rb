# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"

# `func :name, on_chip: true` on a Super FX cartridge: the routine's statements run on the chip
# while the console waits. A game with such routines plays as it does on the interpreter, frame by
# frame; a heavy loop takes fewer frames there than on the 65816; what the chip cannot do is refused
# in plain words; and on a plain cartridge the word changes no byte.
class TestSNESOnChip < Minitest::Test
  LoweringError = VBlank::IR::Backends::SNES::LoweringError
  SNES = VBlank::IR::Backends::SNES

  private def superfx_game(name, &block) = VBlank.game(name, consoles: %i[snes], variants: { snes: :superfx }, &block)

  # A routine with a loop, an `if`, a `while`, a routine of its own to call, and every sort of sum,
  # run from a game loop that draws what the chip worked out.
  private def game_of_sums
    superfx_game("CHIP SUMS") do
      screen :bitmap
      total = var :total, 1
      evens = var :evens, 0
      steps = var :steps, 0
      left = var :left, 0
      seed = var :seed, 12_345

      func :next_number, on_chip: true do
        seed = ((seed * 1_103) + 12_345) & 0xFFFF
      end

      func :work, on_chip: true do
        repeat(12) do |i|
          call :next_number
          total = total + (seed % 7) - (i / 3)
          if (total & 1) == 0 && i > 2
            evens += 1
          else
            total = total ^ (i << 3)
          end
        end
        left = seed >> 8
        while left > 0
          left = left / 2
          steps += 1
        end
      end

      game_loop do
        call :work
        draw_rect_at 0, 0, (total & 63) + 1, 8, :green
      end
    end
  end

  private def superfx_program(game) = game.program(console: :snes, variant: :superfx)

  def test_a_game_of_chip_routines_plays_as_on_the_interpreter
    run = game_player.run(superfx_program(game_of_sums), frames: 40)

    refute_equal 12_345, run[:seed], "the routine ran"
    assert_operator run[:steps], :>, 0, "the `while` ran"
  end

  # Button presses read by the 65816, a routine run only on some passes, and a variable both
  # processors change.
  def test_a_variable_passes_between_the_two_processors
    game = superfx_game("CHIP SHARES") do
      screen :tiled
      shared = var :shared, 5

      func :double, on_chip: true do
        shared = (shared * 2) & 0xFFF
      end

      game_loop do
        shared += 1
        call :double if pressed(:a)
      end
    end
    player = game_player
    player = player.input_each_frame { |frame| (10..12).cover?(frame) ? [:a] : [] }
    run = player.run(superfx_program(game), frames: 30)

    assert_operator run[:shared], :>, 30, "the routine doubled it"
  end

  # A branch reaches 127 bytes: here an `if` and a loop go over more than that, past the chip's 512
  # bytes of quick memory too, and a loop whose count is nought or below runs nothing.
  def test_a_routine_longer_than_a_branch_reaches_plays_as_on_the_interpreter
    game = superfx_game("CHIP LONG") do
      total = var :total, 3
      turns = var :turns, 0
      other = var :other, 0
      never = var :never, -2

      func :long, on_chip: true do
        repeat(turns) do |i|
          if i % 2 == 0
            40.times { total = (total * 5) + i }
          else
            40.times { total = (total ^ 3) - i }
          end
        end
        repeat(never) { total = 0 }
        repeat(0) { total = 0 }
        other = total
        other -= 1
      end

      game_loop do
        turns += 1
        call :long
      end
    end
    run = game_player.run(superfx_program(game), frames: 12)

    refute_equal 0, run[:other], "the routine ran"
  end

  private def heavy_game(on_chip:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes, variant: :superfx))
    b.instance_eval do
      total = var :total, 0
      func :heavy, on_chip: on_chip do
        repeat(500) { |i| total.store!(total + (i * 3) - (total >> 2)) }
      end
      game_loop { call :heavy }
    end
    b.finalize_program
    b.program
  end

  private def frames_a_pass(program)
    run = SNES::HeadlessRun.new.run(program, frames: 12)
    (6...11).map { |pass| run.frames_took(pass) }.max
  end

  def test_a_heavy_loop_takes_fewer_frames_on_the_chip
    on_console = frames_a_pass(heavy_game(on_chip: false))
    on_the_chip = frames_a_pass(heavy_game(on_chip: true))

    assert_operator on_console, :>, 1, "the loop is heavy enough to measure"
    assert_operator on_the_chip, :<, on_console, "the chip took fewer frames"
  end

  private def refusal_of(&body)
    game = superfx_game("REFUSED", &body)
    assert_raises(LoweringError) { game.build_rom(console: :snes, variant: :superfx, profile: false, out: nil, err: nil) }
  end

  def test_a_list_in_a_chip_routine_is_refused_by_name
    error = refusal_of do
      cells = list :cells, capacity: 4
      seen = var :seen, 0
      func(:spin, on_chip: true) { seen = cells[0] }
      game_loop { call :spin }
    end

    assert_match(/spin/, error.message)
    assert_match(/list/, error.message)
    assert_match(/move/i, error.message)
  end

  def test_a_drawing_in_a_chip_routine_is_refused_by_name
    error = refusal_of do
      screen :bitmap
      func(:spin, on_chip: true) { fill_rect 0, 0, 8, 8, :red }
      game_loop { call :spin }
    end

    assert_match(/spin/, error.message)
    assert_match(/fill_rect|draw/, error.message)
  end

  def test_a_fraction_in_a_chip_routine_is_refused_by_name
    error = refusal_of do
      speed = var :speed, 1.5
      other = var :other, 2.5
      func(:spin, on_chip: true) { other = other * speed }
      game_loop { call :spin }
    end

    assert_match(/fraction/, error.message)
  end

  def test_a_wait_in_a_chip_routine_is_refused_by_name
    build = VBlank::IR::Build
    program = build.program(build.func(:spin, build.wait_vblank, on_chip: true), build.func(:outer, build.call(:spin)),
                            build.call(:outer), build.halt, console: :snes, variant: :superfx)
    error = assert_raises(LoweringError) { SNES.new.build(program) }

    assert_match(/spin/, error.message)
    assert_match(/wait/, error.message)
  end

  def test_a_call_of_a_routine_off_the_chip_is_refused_by_name
    error = refusal_of do
      count = var :count, 0
      func(:plain) { count += 1 }
      func(:spin, on_chip: true) { call :plain }
      game_loop { call :spin }
    end

    assert_match(/spin/, error.message)
    assert_match(/plain/, error.message)
  end

  # A routine nothing calls never runs, and is not refused, as on every other backend.
  def test_a_routine_nothing_calls_is_not_refused
    game = superfx_game("UNCALLED") do
      func(:spin, on_chip: true) { fill_rect 0, 0, 8, 8, :red }
      game_loop { nil }
    end

    assert game.build_rom(console: :snes, variant: :superfx, profile: false, out: nil, err: nil)
  end

  private def plain_digest(on_chip:)
    game = VBlank.game("PLAIN", consoles: %i[snes]) do
      screen :bitmap
      total = var :total, 0
      func(:work, on_chip: on_chip) { total += 1 }
      game_loop do
        call :work
        fill_rect 0, 0, 8, 8, :red
      end
    end
    Digest::SHA256.hexdigest(game.build_rom(console: :snes, profile: false, out: nil, err: nil).bytes)
  end

  private def warnings_of_build(variant: nil)
    game = VBlank.game("NO CHIP", consoles: %i[snes]) do
      total = var :total, 0
      func(:work, on_chip: true) { total += 1 }
      game_loop { call :work }
    end
    err = StringIO.new
    game.build_rom(console: :snes, variant: variant, profile: false, out: StringIO.new, err: err)
    err.string
  end

  def test_the_word_on_a_cartridge_with_no_chip_says_so
    assert_match(/:work says `on_chip: true`/, warnings_of_build)
    assert_match(/superfx/, warnings_of_build)
  end

  def test_the_word_on_a_cartridge_with_the_chip_says_nothing
    refute_match(/on_chip/, warnings_of_build(variant: :superfx))
  end

  def test_the_word_changes_no_byte_of_a_plain_cartridge
    assert_equal plain_digest(on_chip: nil), plain_digest(on_chip: true)
  end
end
