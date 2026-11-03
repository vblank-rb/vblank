# frozen_string_literal: true

require "test_helper"

# A SHORT QUEUE OF TWO-BYTE NUMBERS costs a few dozen cycles an operation, as a queue of bytes does
# (TestGBCByteLists). Each pass here makes three hundred operations, which at the thousands of
# cycles a push once cost would take many frames.
class TestGBCHalfLists < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  def test_a_queue_of_halves_keeps_a_frame_a_pass
    frames = [20, 80].map { |passes| GBC::HeadlessRun.new.run(queue_game, frames: passes)[:shown] }

    assert_equal 60, frames.last - frames.first
  end

  # The ring comes round its capacity, a number keeps its low 16 bits, and a half reads back with
  # its top bit as its sign.
  def test_a_queue_of_halves_coming_round_agrees_with_the_interpreter
    GBC::CheckedRun.new.run(ring_game, frames: 40)
    pass
  end

  # A game with queues of bytes and of halves has one push and one item routine answering to both
  # names, since those routines sit in the part of the cartridge always in view.
  def test_queues_of_bytes_and_halves_share_one_push_and_one_item_routine
    code = GBC.new.build(mixed_game).built.code

    assert_equal code.fetch("rt_byte_list_push"), code.fetch("rt_half_list_push")
    assert_equal code.fetch("rt_byte_list_item"), code.fetch("rt_half_list_item")
  end

  # A game that keeps no list of halves carries none of their routines.
  def test_a_game_with_queues_of_bytes_alone_carries_no_routine_for_halves
    code = GBC.new.build(byte_queue_game).built.code

    assert code.key?("rt_byte_list_push")
    assert_empty code.keys.grep(/\Art_(half|narrow)_list/)
  end

  # Through the shared routines each list keeps its own width: a byte keeps its low 8 bits, a
  # half its low 16, each read back with its top bit as its sign, round both rings.
  def test_queues_of_bytes_and_halves_side_by_side_agree_with_the_interpreter
    GBC::CheckedRun.new.run(mixed_game, frames: 40)
    pass
  end

  def test_a_push_onto_a_full_list_of_halves_beside_a_queue_of_bytes_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 5) do
        bytes = list :bytes, capacity: 4, width: :byte
        bytes.push 1
        bytes.shift
        xs = list :xs, capacity: 2, width: :half
        game_loop { xs.push 900 }
      end
    end

    assert_match(/:xs/, error.message)
    assert_match(/full/, error.message)
  end

  def test_a_push_onto_a_full_list_of_halves_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 5) do
        xs = list :xs, capacity: 2, width: :half
        xs.push 1
        xs.shift
        game_loop { xs.push 900 }
      end
    end

    assert_match(/:xs/, error.message)
    assert_match(/full/, error.message)
  end

  def test_a_shift_from_an_empty_list_of_halves_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 5) do
        xs = list :xs, capacity: 4, width: :half
        xs.push 1
        game_loop { xs.shift }
      end
    end

    assert_match(/:xs/, error.message)
    assert_match(/empty/, error.message)
  end

  def test_a_read_past_the_end_of_a_queue_of_halves_stops_the_game_in_the_interpreters_words
    error = assert_raises(VBlank::IR::ProgramError) do
      played(frames: 5) do
        xs = list :xs, capacity: 4, width: :half
        xs.push 1
        xs.push 2
        xs.shift
        n = var :n, 3
        x = var :x, 0
        game_loop { x = xs[n] }
      end
    end

    assert_match(/index 3 is out of range for list :xs \(valid indexes are 0\.\.0\)/, error.message)
  end

  private def played(frames:, &game)
    GBC::CheckedRun.new.run(game_of(&game), frames: frames)
  end

  private def game_of(&game)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:dot, "#" => :white) { "##\n##" }
      sprite :dot, at: [8, 8]
      instance_eval(&game)
    end
    b.finalize_program
    b.program
  end

  private def queue_game
    game_of do
      xs = list :xs, capacity: 32, width: :half
      total = var :total, 0
      shown = var :shown, 0
      game_loop do
        75.times do
          xs.push 700
          total += xs[0]
          total += xs.length
          xs.shift
        end
        shown = frames_since_power_on
      end
    end
  end

  private def byte_queue_game
    game_of do
      xs = list :xs, capacity: 4, width: :byte
      total = var :total, 0
      game_loop do
        xs.push 7
        total += xs[0]
        xs.shift
      end
    end
  end

  private def mixed_game
    game_of do
      bytes = list :bytes, capacity: 3, width: :byte
      halves = list :halves, capacity: 5, width: :half
      n = var :n, 0
      total = var :total, 0
      game_loop do
        n += 1
        bytes.push (n * 37) - 100
        halves.push (n * 9001) - 100_000
        halves.push n * 300
        total = (total * 3) + bytes[0] + (halves[halves.length - 1] * 2) + halves[0] + bytes.length
        bytes.shift if bytes.length > 1
        halves.shift
        halves.shift if halves.length > 2
      end
    end
  end

  private def ring_game
    game_of do
      xs = list :xs, capacity: 5, width: :half
      n = var :n, 0
      total = var :total, 0
      game_loop do
        n += 1
        xs.push (n * 9001) - 100_000
        xs.push n * 300
        total = (total * 3) + xs[0] + (xs[xs.length - 1] * 2) + xs.length
        xs.shift
        xs.shift if xs.length > 2
      end
    end
  end
end
