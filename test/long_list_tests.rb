# frozen_string_literal: true

# A LIST OF MORE THAN 65,535 SLOTS, played on a console with the memory for it, as the interpreter
# plays it: filled a push at a time, then 70,000 taken from the front and 70,000 more pushed, so the
# first item's place and the count both pass what sixteen bits hold and the items go round the ring.
# A console's test includes LongListTests and names the width of the slots it has room for
# (LIST_WIDTH): the PlayStation's 2 megabytes hold words, the Advance's 256K of roomy memory bytes.
# The Advance's cartridge test (test/lowering/gba/vblank/) includes LongListGames; the consoles that
# cannot hold such a list refuse it as the game is built (test/all/vblank/test_list.rb).
module LongListGames
  SLOTS = 100_000
  TAKEN = 70_000
  READINGS = %i[filled first_filled last_filled length first last].freeze

  def self.game(width) = proc do
    big = list :big, capacity: SLOTS, width: width
    readings = READINGS.to_h { |name| [name, var(name, 0)] }
    repeat(SLOTS) { |i| big.push i }
    readings[:filled] = big.length
    readings[:first_filled] = big[0]
    readings[:last_filled] = big[SLOTS - 1]
    repeat(TAKEN) { big.shift }
    repeat(TAKEN) { |i| big.push i + SLOTS }
    readings[:length] = big.length
    readings[:first] = big[0]
    readings[:last] = big[SLOTS - 1]
    game_loop { wait_vblank }
  end

  # What every reading holds once the game has run, an item kept to the low bits of its slot and
  # read back with the slot's top bit as its sign.
  def self.expected(width)
    bits = { byte: 8, half: 16, word: 32 }.fetch(width)
    kept = ->(number) { ((number + (1 << (bits - 1))) % (1 << bits)) - (1 << (bits - 1)) }
    [SLOTS, kept.(0), kept.(SLOTS - 1), SLOTS, kept.(TAKEN), kept.(SLOTS + TAKEN - 1)]
  end
end

module LongListTests
  def test_a_list_of_more_than_65535_slots_plays_as_the_interpreter_plays_it
    width = self.class::LIST_WIDTH
    builder = VBlank::Builder.new
    builder.instance_eval(&LongListGames.game(width))
    builder.finalize_program
    run = game_player.run(builder.program, frames: 2)

    assert_equal LongListGames.expected(width), LongListGames::READINGS.map { |name| run[name] }
  end
end
