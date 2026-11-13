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
      screen :tiled, backdrop: :black
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

  # A routine the chip takes several frames over, called on every pass: the frames still count, a
  # press made and let go while the chip works is still seen, and a song still moves on, as on the
  # interpreter, which reads the buttons and moves the music on at every frame however long a pass is.
  # Turns enough for three frames a pass, with the song's passes ending a few lines into a blank,
  # where the shipped cartridge goes straight on without waiting (Frame#emit_sleep_unless_in_blank).
  CHIP_TURNS = 4300
  PRESSED_ON = [17, 24, 31, 38, 45, 52].freeze

  private def long_chip_run(song: false)
    superfx_game("CHIP LONG RUN") do
      if song
        enable_sound
        song(:tune) { voice(:lead) { 16.times { note :C4, :eighth; note :E4, :sixteenth } } }
        play_song :tune
      end
      total = var :total, 0
      presses = var :presses, 0
      frames = var :frames, 0
      func :heavy, on_chip: true do
        repeat(CHIP_TURNS) { |i| total.store!(total + (i * 3) - (total >> 2)) }
      end
      game_loop do
        call :heavy
        presses += 1 if pressed(:a)
        frames = frames_since_power_on
      end
    end
  end

  private def frames_of_long_chip_run
    run = SNES::HeadlessRun.new.run(superfx_program(long_chip_run), frames: 30)
    (2...8).map { |pass| run.frames_took(pass) }.min
  end

  def test_a_chip_run_of_several_frames_is_long_enough_to_test
    assert_operator frames_of_long_chip_run, :>=, 3, "the chip takes several frames a pass"
  end

  def test_a_press_made_and_let_go_inside_a_long_chip_run_is_counted_as_on_the_interpreter
    player = game_player.input_each_frame { |frame| PRESSED_ON.include?(frame) ? [:a] : [] }
    run = player.run(superfx_program(long_chip_run), frames: 70)

    assert_equal PRESSED_ON.length, run[:presses], "every press was seen"
  end

  def test_frames_since_power_on_across_long_chip_runs_agrees_with_the_interpreter
    run = game_player.run(superfx_program(long_chip_run), frames: 40)

    assert_operator run[:frames], :>=, 30, "the frames the chip ran through were counted"
  end

  def test_the_shipped_song_game_ends_passes_in_the_blank
    run = SNES::HeadlessRun.new.run(superfx_program(long_chip_run(song: true)), frames: 30)

    refute_empty run.passes_missed, "no pass went on without waiting, so the song test below checks nothing of it"
  end

  def test_a_song_across_long_chip_runs_agrees_with_the_interpreter
    run = game_player.run(superfx_program(long_chip_run(song: true)), frames: 60)

    assert_operator run[:frames], :>=, 50, "the song played on through the chip's runs"
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

  # Items added at the back on the chip until each list is full, then taken from the back until it
  # is empty, over and over: narrow slots keep their low bits and read back with their sign, and
  # the 65816 reads what the chip left.
  def test_pushes_and_pops_on_the_chip_play_as_on_the_interpreter
    game = superfx_game("CHIP PUSH") do
      bytes = list :bytes, capacity: 4, width: :byte
      halves = list :halves, capacity: 4, width: :half
      words = list :words, capacity: 4
      step = var :step, 0
      seen = var :_seen, 0
      top = var :_top, 0
      func :grow, on_chip: true do
        if step % 8 < 4
          bytes.push step * 70
          halves.push (step * 30_000) - 50_000
          words.push step - 100_000
        else
          bytes.pop
          halves.pop
          words.pop
        end
        seen = 0
        seen = bytes[bytes.length - 1] + halves[0] if bytes.length > 0
      end
      game_loop do
        call :grow
        top = 0
        top = words[words.length - 1] if words.length > 0
        step += 1
      end
    end
    run = game_player.run(superfx_program(game), frames: 20)

    assert_operator run[:step], :>=, 16, "two rounds of filling and emptying were checked"
  end

  def test_a_push_onto_a_full_list_on_the_chip_stops_the_game
    game = superfx_game("CHIP FULL") do
      cells = list :cells, capacity: 3
      func(:grow, on_chip: true) { cells.push 7 }
      game_loop { call :grow }
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 8) }

    assert_match(/list :cells is full/, error.message)
  end

  def test_a_pop_from_an_empty_list_on_the_chip_stops_the_game
    game = superfx_game("CHIP EMPTY") do
      cells = list :cells, capacity: 4
      cells.push 1
      cells.push 2
      func(:shrink, on_chip: true) { cells.pop }
      game_loop { call :shrink }
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 8) }

    assert_match(/list :cells is empty: there is nothing to pop/, error.message)
  end

  # A whole list, and a run of one from an index worked out as the game runs, with a count of
  # nought or below setting nothing.
  def test_fills_on_the_chip_play_as_on_the_interpreter
    game = superfx_game("CHIP FILL") do
      bytes = list :bytes, capacity: 6, width: :byte, full_of: 0
      words = list :words, capacity: 5, full_of: 1
      step = var :step, 0
      from = var :_from, 0
      count = var :_count, 0
      func :paint, on_chip: true do
        from = step % 3
        count = (step % 4) - 1
        bytes.fill step * 50
        words.fill step - 70_000, from: from, count: count
        bytes.fill step * -3, from: from + 1, count: count + 1
      end
      game_loop do
        call :paint
        step += 1
      end
    end
    run = game_player.run(superfx_program(game), frames: 14)

    assert_operator run[:step], :>=, 12, "every from and count was checked"
  end

  def test_a_fill_past_the_end_of_a_list_on_the_chip_stops_the_game
    game = superfx_game("CHIP FILL FAULT") do
      cells = list :cells, capacity: 4, full_of: 0
      at = var :at, 0
      func(:paint, on_chip: true) { cells.fill 9, from: at, count: 2 }
      game_loop do
        call :paint
        at += 1
      end
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 8) }

    assert_match(/index 4 is out of range for list :cells/, error.message)
  end

  # A list taken from the front goes round its slots like a ring. Shifted on the chip and on the
  # 65816 both, it is read and written by index on the chip as on the interpreter.
  def test_a_list_shifted_on_either_processor_plays_on_the_chip_as_on_the_interpreter
    game = superfx_game("CHIP RING") do
      queue = list :queue, capacity: 4
      step = var :step, 0
      last = var :_last, 0
      func :turn, on_chip: true do
        queue.push step * 3
        queue[0] = queue[0] + 1
        last = queue[queue.length - 1]
        queue.shift if step % 3 == 0
      end
      game_loop do
        call :turn
        queue.shift if queue.length > 2
        step += 1
      end
    end
    run = game_player.run(superfx_program(game), frames: 30)

    assert_operator run[:step], :>=, 20, "the ring went round several times"
  end

  def test_a_shift_of_an_empty_list_on_the_chip_stops_the_game
    game = superfx_game("CHIP EMPTY FRONT") do
      cells = list :cells, capacity: 4
      cells.push 1
      func(:shrink, on_chip: true) { cells.shift }
      game_loop { call :shrink }
    end
    error = assert_raises(VBlank::IR::ProgramError) { game_player.run(superfx_program(game), frames: 8) }

    assert_match(/list :cells is empty: there is nothing to shift/, error.message)
  end

  # A run of a table copied into a list, from each way a table keeps its entries: a byte with a sign
  # and one without (200 reading back as -56 from the list), a half with a sign, a whole word. The
  # start is worked out as the game runs and goes below nought and past the end, where it is held
  # so the run stays inside the table; a list the game shifts starts again from its first slot.
  def test_runs_copied_from_tables_on_the_chip_play_as_on_the_interpreter
    game = superfx_game("CHIP COPY") do
      signed_bytes = table :signed_bytes, [-3, 5, -128, 127, 9, -1], width: :byte
      bytes = table :bytes, [200, 1, 255, 128, 7], width: :byte
      halves = table :halves, [-30_000, 4, 32_767, -2, 600, -7, 11], width: :half
      words = table :words, [-100_000, 70_000, 3, -1, 2_000_000_000], width: :word
      small = list :small, capacity: 4, width: :byte, full_of: 0
      plain = list :plain, capacity: 3, width: :byte, full_of: 0
      mid = list :mid, capacity: 5, width: :half, full_of: 0
      wide = list :wide, capacity: 4, full_of: 0
      queue = list :queue, capacity: 4, width: :half
      step = var :step, 0
      at = var :_at, 0
      seen = var :_seen, 0
      func :load, on_chip: true do
        at = step - 3
        small.copy_from signed_bytes, at: at, count: 4
        plain.copy_from bytes, at: at + 1, count: 3
        mid.copy_from halves, at: step * 2 - 5, count: 5
        wide.copy_from words, at: at, count: 2
        queue.copy_from halves, at: step, count: 3
        seen = small[0] + plain[0] + mid[4] + wide[1] + queue[queue.length - 1]
      end
      game_loop do
        queue.push step
        queue.shift if queue.length > 1
        call :load
        step += 1
      end
    end
    run = game_player.run(superfx_program(game), frames: 14)

    assert_operator run[:step], :>=, 10, "starts below nought and past every table's end were checked"
  end

  # The chip reads a table from one bank of the cartridge, as for a read by index.
  def test_a_run_copied_from_a_table_bigger_than_a_bank_on_the_chip_is_refused_by_name
    error = refusal_of do
      huge = table :huge, Array.new(40_000) { |i| i % 100 }, width: :byte
      cells = list :cells, capacity: 4, width: :byte
      func(:spin, on_chip: true) { cells.copy_from huge, at: 0, count: 4 }
      game_loop { call :spin }
    end

    assert_match(/spin/, error.message)
    assert_match(/huge/, error.message)
    assert_match(/bank/, error.message)
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
