# frozen_string_literal: true

require "test_helper"
require "int32_cases"

# The Super FX's arithmetic gives the answer IR::Int32 gives. The chip is a 16-bit processor, so a
# game's number is two of its registers, and carries, signs and shifts across the middle are where
# it can go wrong: every pair of Int32Cases's values, for every operator an `on_chip` routine can
# use, in the routine's own code (SNES::ChipCode), on the chip, in bsnes.
#
# The cartridge is an ordinary build of a program with one routine for each sum. Each routine works
# out a batch of BATCH sums, in variables the test writes into work RAM. So the numbers travel the
# way a game's do: out to the chip's RAM, back again, and the 65816 sees only variables.
class TestSNESChipInt32 < Minitest::Test
  Build = VBlank::IR::Build
  SNES = VBlank::IR::Backends::SNES
  Int32 = VBlank::IR::Int32

  BATCH = 24
  ROUTINES_A_CARTRIDGE = 12
  OPERATORS = { "add" => :+, "sub" => :-, "mul" => :*, "div" => :/, "mod" => :%, "bit_and" => :&, "bit_or" => :|,
                "bit_xor" => :^, "lt" => :<, "le" => :<=, "gt" => :>, "ge" => :>=, "eq" => :==, "ne" => :!=,
                "both" => :and, "either" => :or }.freeze
  SHIFTING = { "shift_left" => :<<, "shift_right" => :>> }.freeze
  TESTS = %w[lt le gt ge eq ne both either].freeze
  # Numbers written in the program: a shift by a known count, or a division by a power of two, is
  # not made the way one worked out as the game runs is.
  WRITTEN = { "add" => [7, -1, 15, 16, 0x1_0000, -0x1_0000], "sub" => [7, -1, 0x1_0000], "mul" => [3, 16, -1, 0x1_0000],
              "div" => [1, 2, 8, 3, -2, 0x1_0000, 1 << 30], "mod" => [1, 16, 3, -16, 0x1_0000, 1 << 30],
              "bit_and" => [0xFF, -0x1_0000], "bit_or" => [1, 0x1_0000], "bit_xor" => [-1],
              "shift_left" => Int32Cases::SHIFTS + [8, 12, 17, 24], "shift_right" => Int32Cases::SHIFTS + [8, 12, 17, 24],
              "lt" => [0, 7, -1], "eq" => [0, 0x1_0000] }.freeze

  private def op_of(name) = OPERATORS[name] || SHIFTING.fetch(name)
  private def left(index) = Build.var_ref(:"left#{index}")
  private def right(index) = Build.var_ref(:"right#{index}")

  private def plain(name) = ->(i) { Build.set(:"answer#{i}", Build.binop(op_of(name), left(i), right(i))) }

  private def written(name, number)
    ->(i) { Build.set(:"answer#{i}", Build.binop(op_of(name), left(i), Build.int(number))) }
  end

  private def written_on_left(name, number)
    ->(i) { Build.set(:"answer#{i}", Build.binop(op_of(name), Build.int(number), right(i))) }
  end

  # The test as an `if` chooses, which branches on it rather than making a 1 or a 0 of it.
  private def tested(name)
    lambda do |i|
      choice = Build.if_(Build.binop(op_of(name), left(i), right(i)), Build.set(:"answer#{i}", 1))
      choice.else = Build.else_(Build.set(:"answer#{i}", 0))
      choice
    end
  end

  # One cartridge of +routines+ ({ name => what it does with batch entry i }), and the answers of
  # every sum in +cases+ ([routine, a, b]), compared with +answer+.
  private def assert_sums_agree(routines, cases)
    wrong = []
    with_cartridge(routines) do |core, places|
      cases.group_by(&:first).each do |name, group|
        group.each_slice(BATCH) do |batch|
          sums = batch.map { |_, a, b| [a, b] }
          answers(core, places, routines.keys.index(name), sums).zip(batch).each do |got, (_, a, b, want)|
            wrong << "#{name}(#{a}, #{b}) gave #{got}, not #{want}" unless got == want
          end
        end
      end
    end
    assert_empty wrong.first(30), "#{wrong.size} sums were wrong; the first of them are listed"
  end

  private def pairs = Int32Cases::VALUES.product(Int32Cases::VALUES)

  def test_every_pair_of_numbers_matches_int32
    routines = OPERATORS.keys.to_h { |name| [name, plain(name)] }
    cases = routines.keys.flat_map do |name|
      pairs.map { |a, b| [name, a, b, Int32Cases.expected(name, a, b, 0)] }
    end
    assert_sums_agree(routines, cases)
  end

  def test_a_shift_by_a_count_worked_out_matches_int32
    routines = SHIFTING.keys.to_h { |name| [name, plain(name)] }
    cases = routines.keys.flat_map do |name|
      Int32Cases::VALUES.product(Int32Cases::SHIFTS + [2**31, 65_536, 65_537, -65_536])
                        .map { |a, b| [name, Int32.wrap(a), Int32.wrap(b), Int32Cases.expected(name, a, Int32.wrap(b), 0)] }
    end
    assert_sums_agree(routines, cases)
  end

  def test_a_test_an_if_branches_on_matches_int32
    routines = TESTS.to_h { |name| ["if #{name}", tested(name)] }
    cases = TESTS.flat_map { |name| pairs.map { |a, b| ["if #{name}", a, b, Int32Cases.expected(name, a, b, 0)] } }
    assert_sums_agree(routines, cases)
  end

  def test_a_number_written_in_the_program_matches_int32
    routines = {}
    cases = WRITTEN.flat_map do |name, numbers|
      numbers.flat_map do |number|
        routine = "#{name} #{number}"
        routines[routine] = written(name, number)
        Int32Cases::VALUES.map { |a| [routine, a, 0, Int32Cases.expected(name, a, number, 0)] }
      end
    end
    # All of the chip's code is in one bank, and so many sums written out are more than one holds.
    routines.each_slice(ROUTINES_A_CARTRIDGE) do |some|
      names = some.map(&:first)
      assert_sums_agree(some.to_h, cases.select { |routine, _, _, _| names.include?(routine) })
    end
  end

  def test_a_number_written_on_the_left_matches_int32
    routines = {}
    cases = %w[sub div mod lt shift_left].product([7, -7, 0x1_0000]).flat_map do |name, number|
      routine = "#{number} #{name}"
      routines[routine] = written_on_left(name, number)
      Int32Cases::VALUES.map { |b| [routine, 0, b, Int32Cases.expected(name, number, b, 0)] }
    end
    assert_sums_agree(routines, cases)
  end

  # Sums inside sums, so a side worked out has to be kept somewhere while the other one is, and the
  # routines the sums call must not spoil what is kept.
  def test_a_sum_of_sums_matches_int32
    deep = ->(a, b) { Int32.sub(Int32.mul(Int32.add(a, b), Int32.sub(a, b)), Int32.div(Int32.mod(a, 7), Int32.bit_or(b, 1))) }
    routines = {
      "deep" => lambda do |i|
        sum = Build.binop(:*, Build.binop(:+, left(i), right(i)), Build.binop(:-, left(i), right(i)))
        rest = Build.binop(:/, Build.binop(:%, left(i), Build.int(7)), Build.binop(:|, right(i), Build.int(1)))
        Build.set(:"answer#{i}", Build.binop(:-, sum, rest))
      end
    }
    assert_sums_agree(routines, pairs.map { |a, b| ["deep", a, b, deep.call(a, b)] })
  end

  # +sums+ ([a, b]) worked out by the routine numbered +number+.
  private def answers(core, places, number, sums)
    sums.each_with_index do |(a, b), i|
      { "left" => a, "right" => b }.each do |side, number|
        at = places[:"#{side}#{i}"] # a routine with a number written on one side has no variable there
        core.wram_write32(at, number) if at
      end
    end
    done = core.wram_read32(places.fetch(:done))
    core.wram_write32(places.fetch(:go), number + 1)
    frames = 0
    while core.wram_read32(places.fetch(:done)) == done
      core.run_frame
      frames += 1
      flunk "the cartridge did not finish a batch in 600 frames" if frames > 600
    end
    Array.new(sums.size) { |i| Int32.wrap(core.wram_read32(places.fetch(:"answer#{i}"))) }
  end

  private def with_cartridge(routines)
    rom = SNES.new.build(program_of(routines), title: "CHIP SUMS")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "chip.sfc")
      rom.write(path)
      core = VBlank::Diagnostics::Emulator.open_snes(path)
      3.times { core.run_frame } # booted: boot clears all of work RAM
      yield core, rom.built.variables
    ensure
      core&.destroy
    end
  end

  # A game that does nothing until the test says which routine to run.
  private def program_of(routines)
    funcs = routines.map do |name, step|
      Build.func(name.to_sym, *Array.new(BATCH) { |i| step.call(i) }, on_chip: true)
    end
    run = Build.if_(Build.var_ref(:go),
                    Build.call_one_of(routines.keys.map(&:to_sym), which: Build.binop(:-, Build.var_ref(:go), Build.int(1))),
                    Build.set(:go, 0), Build.add(:done, 1))
    Build.program(Build.screen(:tiled), *funcs, Build.loop_(Build.wait_vblank, run), console: :snes, variant: :superfx)
  end
end
