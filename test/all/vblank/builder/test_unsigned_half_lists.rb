# frozen_string_literal: true

require "test_helper"

# A LIST OR A POOL FIELD OF `width: :unsigned_half`: two bytes read back with no sign, 0 to 65535,
# for a place kept in 256ths of a pixel. A number outside keeps its low sixteen bits. Every run
# plays these, each console's build checked against the interpreter on every pass.
class TestUnsignedHalfLists < Minitest::Test
  # The numbers written, at the edges of 16 bits and below nought, and what each reads back as.
  WRITTEN = [32_767, 32_768, 65_535, 65_536, -1, -32_768].freeze
  READ = [32_767, 32_768, 65_535, 0, 65_535, 32_768].freeze

  def test_a_list_keeps_the_low_sixteen_bits_and_reads_them_with_no_sign
    player = game_player
    player.run(list_game.program(console: VBlank::Testing.console), frames: 3)

    assert_equal READ, player.list(:set_at)
    assert_equal READ, player.list(:pushed)
    assert_equal [4464] * 3, player.list(:filled) # 70000 keeps 70000 - 65536
    assert_equal [65_535, 1], %i[highest past].map { |name| player[name] }
  end

  def test_a_pool_field_keeps_the_low_sixteen_bits_and_reads_them_with_no_sign
    player = game_player
    player.run(pool_game.program(console: VBlank::Testing.console), frames: 4)

    passes = player[:passes]
    # Spawned at 65533 and at -1, which keeps 65535, each a step on every pass, round past 65535.
    assert_equal [65_533 + passes, 65_535 + passes].map { |place| place & 0xFFFF }.sort, player.pool(:mover, :place).compact.sort
  end

  # 65535 is not -1, though its low sixteen bits are the same.
  def test_a_slot_holding_65535_is_not_equal_to_minus_one
    game = VBlank.game("NOT MINUS ONE", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      places = list :places, capacity: 2, width: :unsigned_half, full_of: 65_535
      equal = 0
      unequal = 0
      game_loop do
        equal = 1 if places[0] == -1
        unequal = 1 if places[1] != -32_768
      end
    end
    player = game_player
    player.run(game.program(console: VBlank::Testing.console), frames: 2)

    assert_equal [0, 1], %i[equal unequal].map { |name| player[name] }
  end

  # A list loaded from save memory keeps the low sixteen bits of what the save holds, so it still
  # holds 0..65535 whatever a save written by another game put there.
  def test_a_list_loaded_from_save_memory_keeps_its_range
    program = VBlank.game("SAVED PLACES", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      places = list :places, capacity: 2, width: :unsigned_half, full_of: 0
      file = save_data(:file) { keep places }
      file[0].load
      game_loop { wait_vblank }
    end.program(console: VBlank::Testing.console)
    image = Reference.save_into(SaveImage.new, program, :file, 0, places: [-1, 65_536])
    player = game_player(save: image)
    player.run(program, frames: 2)

    assert_equal [65_535, 0], player.list(:places)
  end

  def test_one_holding_fractions_is_refused
    [-> { list :speeds, capacity: 2, width: :unsigned_half, full_of: 0.5 },
     -> { pool :mover, speed: 0.5, capacity: 2, widths: { speed: :unsigned_half } }].each do |declare|
      error = assert_raises(ArgumentError) do
        VBlank.game("FRACTIONS", consoles: %i[gba gbc snes genesis ps1]) do
          screen :bitmap
          instance_exec(&declare)
          game_loop { wait_vblank }
        end.program(console: VBlank::Testing.console)
      end
      assert_match(/fraction/, error.message)
    end
  end

  def test_a_copy_from_a_table_into_one_is_refused
    error = assert_raises(ArgumentError) do
      VBlank.game("COPY", consoles: %i[gba gbc snes genesis ps1]) do
        screen :bitmap
        steps = table :steps, [1, 2, 3, 4], width: :word
        places = list :places, capacity: 4, width: :unsigned_half
        game_loop { places.copy_from steps, at: 0, count: 4 }
      end.program(console: VBlank::Testing.console)
    end
    assert_match(/0 to 65535/, error.message)
  end

  private def list_game
    written = WRITTEN
    VBlank.game("UNSIGNED LISTS", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      set_at = list :set_at, capacity: 6, width: :unsigned_half, full_of: 0
      pushed = list :pushed, capacity: 6, width: :unsigned_half
      filled = list :filled, capacity: 3, width: :unsigned_half, full_of: 70_000
      highest = 0
      past = 0
      done = 0
      game_loop do
        if done == 0
          written.each_with_index do |number, i|
            set_at[i] = number
            pushed.push number
          end
          done = 1
        end
        highest = set_at[2]
        past = set_at[2] + 1 - 65_535
      end
    end
  end

  private def pool_game
    VBlank.game("UNSIGNED FIELDS", consoles: %i[gba gbc snes genesis ps1]) do
      screen :bitmap
      movers = pool :mover, place: 0, capacity: 4, widths: { place: :unsigned_half }
      movers.spawn(place: 65_533)
      movers.spawn(place: -1)
      passes = 0
      game_loop do
        passes += 1
        movers.each { |m| m.place += 1 }
      end
    end
  end
end
