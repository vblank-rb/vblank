# frozen_string_literal: true

require "test_helper"

# The programs these tests compute, each with the answers Ruby gives for it, shared with the
# Advance's cartridge's tests (test/lowering/gba/vblank/dsl/test_bit_operations_cartridge.rb). A
# case is [expected, program block]: the variables it must end with, and the game that works
# them out.
module BitOperationsCases
  include SharedConstants

  B = VBlank::IR::Build

  # A 16x16 solidity shape: one bit per pixel, sixteen 16-bit rows, the top bit of a
  # row being its leftmost pixel. This is how a real console keeps per-pixel collision,
  # and the shape is a staircase so that a test notices bits read in the wrong order.
  SHAPE = (0..15).map { |y| (0xFFFF << y) & 0xFFFF }.freeze

  # A background map cell as the hardware packs one: the tile number in the low ten
  # bits, then flip-across and flip-down, then which group of colours it draws from.
  CELL = (3 << 12) | (1 << 11) | (0 << 10) | 0x123

  # Walk every pixel of a collision shape and ask whether it is solid — the thing a
  # game does four times per moving thing per frame, and the reason this feature
  # exists. Counting the solid ones catches a wrong mask; adding up where they are
  # catches bits read in the wrong order, which a count alone would not.
  private def collision_shape_case
    want_solid = 0
    want_where = 0
    256.times do |i|
      next unless SHAPE[i >> 4][15 - (i & 15)] == 1

      want_solid += 1
      want_where += i
    end

    game = proc do
      screen :bitmap
      shape = table :shape, SHAPE, width: :half
      solid = var :solid, 0
      where = var :where, 0
      repeat(256) do |i|
        row = shape[i >> 4]                      # which row of the shape — a shift by 4
        bit = (row >> (15 - (i & 15))) & 1       # ...and one pixel out of that row
        if bit == 1
          solid += 1
          where += i
        end
      end
      halt
    end
    [{ solid: want_solid, where: want_where }, game]
  end

  # Take a packed map cell apart into its four fields and build the same cell back up
  # from them. Every field but the first needs a shift AND a mask, and the tile number
  # needs a mask too big to ride inside an instruction — so this is the one that would
  # catch a backend that only handled small masks.
  private def packed_cell_case
    expected = {
      tile: CELL & 0x3FF, across: (CELL >> 10) & 1, down: (CELL >> 11) & 1,
      bank: (CELL >> 12) & 15, rebuilt: CELL,
    }

    game = proc do
      screen :bitmap
      cell = var :cell, CELL
      tile = var :tile, 0
      across = var :across, 0
      down = var :down, 0
      bank = var :bank, 0
      rebuilt = var :rebuilt, 0

      tile = cell & 0x3FF
      across = (cell >> 10) & 1
      down = (cell >> 11) & 1
      bank = (cell >> 12) & 15
      rebuilt = (bank << 12) | (down << 11) | (across << 10) | tile
      halt
    end
    [expected, game]
  end

  # Flags packed into one word: set one, clear one, turn one over, and test two that
  # are not next to each other. That last is the case with no arithmetic form at all —
  # no amount of dividing and wrapping can ask about bits 2 and 7 in one go.
  private def flags_case
    hurt = 0x04
    armed = 0x80
    packed = hurt | armed | 0x01

    expected = { flags: (packed & ~hurt) ^ 0x01, both: hurt | armed, cleared: packed & ~hurt }

    game = proc do
      screen :bitmap
      flags = var :flags, 0
      both = var :both, 0
      cleared = var :cleared, 0
      mask = var :mask, hurt

      flags = flags | hurt          # set a flag
      flags = flags | armed         # and another
      flags = flags | 0x01
      both = flags & (hurt | armed) # two flags at once, not next to each other
      cleared = flags & ~mask       # clear one through a mask the game works out
      flags = flags & ~hurt          # clear it, the mask written down
      flags = flags ^ 0x01           # turn one over
      halt
    end
    [expected, game]
  end

  # The ends of the range, where the chip and Ruby have different instincts and the
  # two backends could quietly disagree. A count of 32 or more empties the number, and
  # so does a negative count — it does NOT turn round and shift the other way, which is
  # what Ruby itself would do with one.
  private def shift_past_end_case
    expected = {
      up_far: 0, down_far: -1, up_back: 0, down_back: 0,
      down_negative: -4, up_round: 0, down_round: -1,
    }

    game = proc do
      screen :bitmap
      far = var :far, 40
      back = var :back, -1
      round = var :round, 256
      one = var :one, 1
      low = var :low, -256

      up_far = var :up_far, 0
      down_far = var :down_far, 0
      up_back = var :up_back, 0
      down_back = var :down_back, 0
      down_negative = var :down_negative, 0
      up_round = var :up_round, 0
      down_round = var :down_round, 0

      up_far = one << far            # a count worked out, past the end
      down_far = back >> far         # -1 shifted down stays -1: the sign fills in
      up_back = one << back          # a negative count: off the end, not the other way
      down_back = one >> back
      down_negative = low >> 6       # -256 down six places is -4, keeping its sign
      # A count of 256 is the one the chip would get wrong on its own: it reads only
      # the low byte of a count, and 256's low byte is zero, so left alone it would
      # shift by nothing at all instead of emptying the number.
      up_round = one << round
      down_round = low >> round
      halt
    end
    [expected, game]
  end

  # The same rule with the count WRITTEN DOWN. The DSL turns that away (a count nobody
  # can have meant — see below), so this goes through the IR directly: a backend has to
  # honour the contract for any tree it is handed, whatever the surface happens to
  # allow, and the build settles a written-down count instead of emitting a shift.
  # [expected, program].
  private def written_down_count_case
    program = B.program(
      B.screen(:bitmap),
      B.set(:up, B.binop(:<<, B.int(1), B.int(40))),            # 0 — off the top end
      B.set(:down, B.binop(:>>, B.int(-1), B.int(40))),         # -1 — the sign fills in
      B.set(:down_positive, B.binop(:>>, B.int(255), B.int(-1))), # 0 — a negative count
      B.halt,
    )
    [{ up: 0, down: -1, down_positive: 0 }, program]
  end

  # Numbers either side of nought and of each half's edge, a byte's edge among them, since a
  # console with 16-bit halves may move a whole byte or half at once and work out only the places
  # left over.
  EDGES = [0, 1, -1, 0x7F, 0x80, 0x7FFF, 0x8000, -0x8000, 0xFFFF, -0x10000, 0x12345678, -0x12345678,
           0x7FFFFFFF, -0x80000000].freeze

  # Every count from 0 to 31 written down, both ways, on each of EDGES: the count of numbers that
  # come out other than Ruby's, which must be none.
  private def every_written_count_case
    wrong_left = 0
    wrong_right = 0
    game = proc do
      screen :bitmap
      left = var :wrong_left, 0
      right = var :wrong_right, 0
      EDGES.each_with_index do |written, i|
        number = var :"edge#{i}", written
        32.times do |count|
          left += 1 if (number << count) != VBlank::IR::Int32.shift_left(written, count)
          right += 1 if (number >> count) != VBlank::IR::Int32.shift_right(written, count)
        end
      end
      halt
    end
    [{ wrong_left: wrong_left, wrong_right: wrong_right }, game]
  end

  # A written mask that keeps one half whole and decides the other whatever it held — `& 0xFFFF`
  # empties the high half and keeps the low one — beside masks that do neither, on each side of
  # the operator, against Ruby's answers.
  private def masks_on_halves_case
    masks = [0xFFFF, -0x10000, 0xFFFF00FF, 0x00FF0000, 0, -1]
    expected = {}
    EDGES.each_with_index do |written, i|
      masks.each_with_index do |mask, m|
        expected[:"and#{i}_#{m}"] = VBlank::IR::Int32.wrap(written & mask)
        expected[:"or#{i}_#{m}"] = VBlank::IR::Int32.wrap(written | mask)
        expected[:"xor#{i}_#{m}"] = VBlank::IR::Int32.wrap(mask ^ written)
      end
    end
    game = proc do
      screen :bitmap
      EDGES.each_with_index do |written, i|
        number = var :"edge#{i}", written
        masks.each_with_index do |mask, m|
          var(:"and#{i}_#{m}", 0).store!(number & mask)
          var(:"or#{i}_#{m}", 0).store!(number | mask)
          var(:"xor#{i}_#{m}", 0).store!(mask ^ number)
        end
      end
      halt
    end
    [expected, game]
  end

  # Counts written down past either end, on a number the game holds, so the build cannot settle
  # the shift itself and has to write it: an empty number, or only the sign.
  private def written_count_past_the_end_on_a_variable_case
    program = B.program(
      B.screen(:bitmap),
      B.set(:low, B.int(-256)),
      B.set(:high, B.int(0x40000000)),
      B.set(:up, B.binop(:<<, B.var_ref(:high), B.int(40))),
      B.set(:up_back, B.binop(:<<, B.var_ref(:high), B.int(-1))),
      B.set(:down, B.binop(:>>, B.var_ref(:low), B.int(40))),
      B.set(:down_back, B.binop(:>>, B.var_ref(:high), B.int(-1))),
      B.set(:down_whole, B.binop(:>>, B.var_ref(:low), B.int(31))),
      B.halt,
    )
    [{ up: 0, up_back: 0, down: -1, down_back: 0, down_whole: -1 }, program]
  end

  private def build_program(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end
end

# Reading and writing the bits of a number: `& | ^ ~ << >>` on a Value.
#
# What these are FOR is packed data — a background map cell, a row of a collision
# shape, a word of state flags — so the tests are written as that: a real packed
# format taken apart and put back together, checked against a plain-Ruby model of
# the same thing. A test that restated the operator ("x & 3 is x & 3") would pass
# on a backend that had them all subtly wrong together.
#
# Every program here runs on every run and must agree with Ruby's answer, and the Advance's
# cartridge is held to the same answers in
# test/lowering/gba/vblank/dsl/test_bit_operations_cartridge.rb. The two could differ in
# exactly the places the model can't see — a mask too big to ride inside an instruction, a
# shift count worked out as the game runs, a count past the end of the number — so those are
# what the programs are built out of.
class TestBitOperations < Minitest::Test
  include BitOperationsCases

  # ---------------------------------------------------------------------------
  # what a program COMPUTES (the programs are in BitOperationsCases, above)
  # ---------------------------------------------------------------------------

  def test_reading_one_bit_per_pixel_out_of_a_collision_shape
    expected, game = collision_shape_case
    assert_computes(expected, &game)
  end

  def test_a_packed_map_cell_comes_apart_and_goes_back_together
    expected, game = packed_cell_case
    assert_computes(expected, &game)
  end

  def test_setting_clearing_and_testing_flags_in_one_word
    expected, game = flags_case
    assert_computes(expected, &game)
  end

  def test_a_shift_past_the_end_of_the_number_empties_it
    expected, game = shift_past_end_case
    assert_computes(expected, &game)
  end

  def test_a_written_down_count_past_the_end_is_settled_by_the_build
    expected, program = written_down_count_case

    interpreter = game_player.run(program)
    expected.each { |name, want| assert_equal want, interpreter[name], "the interpreter's #{name}" }
  end

  def test_every_written_down_count_shifts_as_ruby_does
    expected, game = every_written_count_case
    assert_computes(expected, &game)
  end

  def test_a_written_mask_on_either_side_matches_ruby
    expected, game = masks_on_halves_case
    assert_computes(expected, &game)
  end

  # A variable on the left and a sum worked out on the right: a console may read the variable
  # where it is after working the right side out, and it must still take the left away from the
  # right the right way round, and compare them the right way round.
  def test_a_variable_beside_a_worked_out_right_side
    a = -0x12345
    b = 0x7654321
    int = VBlank::IR::Int32
    shifted = int.shift_right(b, 3)
    expected = {
      less: int.wrap(a - shifted), more: int.wrap(a + shifted), masked: int.wrap(a & (b << 4)),
      above: a < shifted ? 1 : 0, below: shifted < a ? 1 : 0, same: a == (b & 0xFFFF) ? 1 : 0,
      grown: int.wrap(a + (b & 0xFF0)), shrunk: int.wrap(a - (b >> 9))
    }
    assert_computes(expected) do
      screen :bitmap
      left = var :left, a
      right = var :right, b
      less = var :less, 0
      more = var :more, 0
      masked = var :masked, 0
      above = var :above, 0
      below = var :below, 0
      same = var :same, 0
      grown = var :grown, a
      shrunk = var :shrunk, a
      less = left - (right >> 3)
      more = left + (right >> 3)
      masked = left & (right << 4)
      above = 1 if left < (right >> 3)
      below = 1 if left > (right >> 3)
      same = 1 if left == (right & 0xFFFF)
      grown += right & 0xFF0
      shrunk -= right >> 9
      halt
    end
  end

  def test_a_written_down_count_past_the_end_on_a_variable_empties_it
    expected, program = written_count_past_the_end_on_a_variable_case

    interpreter = game_player.run(program)
    expected.each { |name, want| assert_equal want, interpreter[name], "the interpreter's #{name}" }
  end

  # A count written into the program that throws the whole number away is a mistake the
  # build can see, so it says so at the line rather than quietly giving 0.
  def test_a_written_down_count_past_the_end_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 1
        out = flags << 40
      end
    end

    assert_match(/off the end/, err.message)
    assert_match(/0 to 31/, err.message)
  end

  def test_a_written_down_negative_count_is_a_friendly_error_naming_the_other_way
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 1
        out = flags >> -2
      end
    end

    assert_match(/cannot go below 0/, err.message)
    assert_match(/`<<`/, err.message)
  end

  # ---------------------------------------------------------------------------
  # the surface: what a person is allowed to write
  # ---------------------------------------------------------------------------

  def test_a_number_written_in_the_program_can_stand_on_the_left
    assert_computes(masked: 0x0F & 0x3C, ored: 0xF0 | 0x0C, xored: 0xFF ^ 0x3C) do
      screen :bitmap
      value = var :value, 0x3C
      masked = var :masked, 0
      ored = var :ored, 0
      xored = var :xored, 0
      masked = 0x0F & value
      ored = 0xF0 | value
      xored = 0xFF ^ value
      halt
    end
  end

  # Ruby routes `& | ^` through #coerce and does not route `<< >>` that way, so the
  # shape a person reaches for first — one bit at a place the game works out — stops
  # with a message naming a class they never wrote. Say what to write instead.
  def test_a_number_on_the_left_of_a_shift_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        col = var :col, 3
        bit = 0x8000 >> col
      end
    end

    assert_match(/worked out as the game runs/, err.message)
    assert_match(/on the left/, err.message)
  end

  # A flag test in C is `if (flags & MASK)`, so `(flags & MASK).then { ... }` is what a
  # person writes here first. Ruby gives every object a `then` of its own, which would
  # run the block while the program is being built and record its body with no test
  # around it — the body running every frame, and nothing said.
  def test_branching_straight_off_a_number_is_a_friendly_error
    opened = false
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 0
        (flags & 4).then { opened = true }
      end
    end

    refute opened, "the block ran, so the body would have been recorded with no test around it"
    assert_match(/not a yes/, err.message)
    assert_match(/!= 0/, err.message)
  end

  def test_a_bit_operation_on_a_number_holding_a_fraction_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        px = var :px, 3.5
        low = px & 15
      end
    end

    assert_match(/whole numbers/, err.message)
    assert_match(/\.to_i/, err.message)
  end

  def test_a_fraction_on_the_right_of_a_bit_operation_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      build_program do
        screen :bitmap
        flags = var :flags, 0
        speed = var :speed, 1.5
        low = flags & speed
      end
    end

    assert_match(/the number on the right/, err.message)
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  private


  # Run one program through the reference interpreter and assert each named variable.
  def assert_computes(expected, &block)
    interpreter = game_player.run(build_program(&block))
    expected.each do |name, want|
      assert_equal want, interpreter[name], "the interpreter's #{name}"
    end
    interpreter
  end
end
