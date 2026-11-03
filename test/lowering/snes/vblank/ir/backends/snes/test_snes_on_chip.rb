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

  MAP_W = 8
  MAP = [
    1, 1, 1, 1, 1, 1, 1, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 0, 1, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 1, 0, 1,
    1, 0, 0, 1, 0, 0, 0, 1,
    1, 0, 0, 0, 0, 0, 0, 1,
    1, 1, 1, 1, 1, 1, 1, 1
  ].freeze
  TURN = 256
  QUARTER = TURN / 4
  SIN = (0...TURN).map { |a| Math.sin(a * 2 * Math::PI / TURN) }.freeze
  COLUMNS = 24
  STEPS = 16
  STEP = 0.25

  # A first-person view's work, as a ray cast does it: a ray for each column of the screen walks a
  # map read from a table, a quarter of a cell at a time, with fractions; its distance is brought
  # back from the fan by a cosine, turned into a wall's height by the perspective divide, held on
  # the screen and written into a list. Ordinary code then reads the list, and draws the walls when
  # +draw+ says so.
  private def ray_cast(on_chip:, draw: false)
    superfx_game("CHIP RAYS") do
      screen :bitmap
      sin = table :sin, SIN
      world = table :world, MAP, width: :byte
      heights = list :heights, capacity: COLUMNS, full_of: 0
      view = var :view, 0
      px = var :px, 3.5
      py = var :py, 3.4
      ang = var :_ang, 0
      dx = var :_dx, 0.0
      dy = var :_dy, 0.0
      rx = var :_rx, 0.0
      ry = var :_ry, 0.0
      hit = var :_hit, 0
      dist = var :_dist, 0.0
      seen = var :_seen, 0.0
      tall = var :_tall, 0
      drawn = var :_drawn, 0

      func :cast, on_chip: on_chip do
        repeat(COLUMNS) do |col|
          ang = view + (col * 2) - (COLUMNS - 1)
          dx = sin[ang + QUARTER] * STEP
          dy = sin[ang] * STEP
          dx = -dx if ang > 300
          rx = px
          ry = py
          hit = 0
          dist = STEPS * STEP
          repeat(STEPS, stop_when: hit == 1) do |step|
            rx += dx
            ry += dy
            if world[(ry.to_i * MAP_W) + rx.to_i] == 1
              hit = 1
              dist = step * STEP
            end
          end
          seen = dist * sin[(col * 2) + (QUARTER - (COLUMNS - 1))]
          tall = (96 / (seen + 0.5)).to_i
          heights[col] = tall.clamp(4, 120) - (tall.abs % 3)
        end
      end

      game_loop do
        view = (view + 5) % TURN
        call :cast
        drawn = 0
        repeat(heights.length) do |col|
          drawn += heights[col]
          draw_rect_at col * 8, 0, 8, heights[col], :white if draw
        end
      end
    end
  end

  def test_a_ray_cast_on_the_chip_plays_as_on_the_interpreter
    run = game_player.run(superfx_program(ray_cast(on_chip: true)), frames: 60)

    assert_operator run[:view], :>=, 25, "five passes or more were checked"
    assert_operator run[:_drawn], :>, 0, "the list the chip wrote was read"
  end

  def test_walls_drawn_from_the_chip_s_list_look_as_on_the_interpreter
    run = game_player.run(superfx_program(ray_cast(on_chip: true, draw: true)), frames: 30)

    assert_operator run[:_drawn], :>, 0, "the walls were drawn from the list the chip wrote"
  end

  # Frames a pass of the ray cast takes, on the 65816 and on the chip, from the console's count.
  private def frames_of_ray_cast(on_chip:)
    run = SNES::HeadlessRun.new.run(superfx_program(ray_cast(on_chip: on_chip)), frames: 40)
    (10...30).map { |pass| run.frames_took(pass) }.max
  end

  def test_a_ray_cast_takes_fewer_frames_on_the_chip
    on_console = frames_of_ray_cast(on_chip: false)
    on_the_chip = frames_of_ray_cast(on_chip: true)
    warn "frames a pass of the ray cast: #{on_console} on the 65816, #{on_the_chip} on the chip" if ENV["VBLANK_CHIP_FRAMES"]

    assert_operator on_the_chip, :<, on_console, "the chip took fewer frames"
  end

  # A table whose length is not a power of two holds an index to its ends rather than wrapping it,
  # below nought as well as past the end; and a narrow slot of a list keeps the low bits and reads
  # back with its sign, on the chip as on the interpreter.
  def test_held_table_indexes_and_narrow_slots_on_the_chip_play_as_on_the_interpreter
    game = superfx_game("CHIP EDGES") do
      odd = table :odd, [5, -6, 7, 300, -9]
      bytes = list :bytes, capacity: 3, width: :byte, full_of: 0
      halves = list :halves, capacity: 2, width: :half, full_of: 0
      step = var :step, 0
      low = var :_low, 0
      high = var :_high, 0
      func :edges, on_chip: true do
        low = odd[step - 3]
        high = odd[step + 2]
        bytes[0] = odd[3] - 100
        bytes[1] = step * 70
        bytes[2] = low
        halves[0] = step * 9000
        halves[1] = high - 70_000
      end
      game_loop do
        step += 1
        call :edges
      end
    end
    run = game_player.run(superfx_program(game), frames: 10)

    assert_operator run[:step], :>=, 5, "passes past both ends were checked"
  end

  # A list the chip reaches lives in the chip's own memory, and the reader of a finished cartridge
  # finds it there as it finds any other list.
  def test_the_reader_reads_a_list_kept_in_the_chip_s_memory
    game = superfx_game("CHIP LIST") do
      cells = list :cells, capacity: 4, full_of: 0
      func :fill, on_chip: true do
        repeat(4) { |at| cells[at] = (at * 7) + 3 }
      end
      call :fill
      game_loop { wait_vblank }
    end
    rom = game.build_rom(console: :snes, variant: :superfx, profile: false, out: nil, err: nil)

    assert_equal [3, 10, 17, 24], VBlank::Diagnostics::Verifier.new(rom, frames: 20, vars: rom.var_addresses).list(:cells)
  end

  # A list read on the chip at an index outside it stops the game, in the interpreter's words.
  def test_a_list_read_out_of_range_on_the_chip_stops_the_game
    game = superfx_game("CHIP FAULT") do
      cells = list :cells, capacity: 4
      cells.push 10
      at = var :at, 0
      got = var :got, 0
      func(:look, on_chip: true) { got = cells[at] }
      game_loop do
        call :look
        at += 1
      end
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 6) }

    assert_match(/index 1 is out of range for list :cells/, error.message)
  end

  # Written on the chip at an index outside it, the same; and a list's length read there.
  def test_a_list_written_out_of_range_on_the_chip_stops_the_game
    game = superfx_game("CHIP FAULT") do
      cells = list :cells, capacity: 4
      cells.push 1
      cells.push 2
      at = var :at, -1
      size = var :size, 0
      func(:put, on_chip: true) do
        cells[at + 1] = at * 3
        size = cells.length
      end
      game_loop do
        call :put
        at += 1
      end
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 6) }

    assert_match(/index 2 is out of range for list :cells/, error.message)
  end

  def test_a_list_taken_from_on_the_chip_is_refused_by_name
    error = refusal_of do
      cells = list :cells, capacity: 4
      func(:spin, on_chip: true) { cells.push 1 }
      game_loop { call :spin }
    end

    assert_match(/spin/, error.message)
    assert_match(/list/, error.message)
    assert_match(/move/i, error.message)
  end

  def test_a_list_too_big_for_the_chip_is_refused_in_plain_words
    error = refusal_of do
      cells = list :cells, capacity: 4000
      seen = var :seen, 0
      func(:spin, on_chip: true) { seen = cells[0] }
      game_loop { call :spin }
    end

    assert_match(/cells/, error.message)
    assert_match(/Super FX/, error.message)
  end

  # A `case_var` changes scene, and a scene sets up the screen as it starts, which only the
  # console can do.
  def test_a_change_of_scene_on_the_chip_is_refused_by_name
    error = refusal_of do
      mode = var :mode, 0
      scene(:one) { mode = 1 }
      func(:pick, on_chip: true) { case_var(:mode) { when_val 0, :one } }
      game_loop { call :pick }
    end

    assert_match(/pick/, error.message)
    assert_match(/case_var/, error.message)
    assert_match(/scene/, error.message)
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
