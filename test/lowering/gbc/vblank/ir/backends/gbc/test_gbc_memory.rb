# frozen_string_literal: true

require "test_helper"

# Where a color game keeps its variables and lists, against what the build checks are told the
# Color has. The checks count a game against the console's description before anything is
# built (Checks::IwramBudget), and the Color's lowering lays the game out here; the two have to
# be talking about the same room, or a game passes the check and is refused anyway.
class TestGBCMemory < Minitest::Test
  include VBlank::IR::Build

  GBC = VBlank::IR::Backends::GBC
  Memory = GBC::Memory
  COLOR = VBlank::Console::COLOR

  def test_the_colors_description_says_how_much_work_memory_there_is
    assert_equal COLOR.work_memory_bytes, Memory::HIGH_END - Memory::SHADOW_OAM
  end

  # No list spans the two halves of work memory, so the most one can take is the banked half,
  # the larger. The description cannot name the lowering, so the number is held to it here.
  def test_the_colors_description_says_the_largest_list_is_the_banked_half
    assert_equal Memory::HIGH_END - Memory::HIGH_START, COLOR.largest_list_bytes
  end

  # What is free for a game is what the least game leaves: the stack, the sprite table's copy and
  # the runtime's own state are in memory before any variable is. Said a little short of it rather
  # than over, so the check never passes a game the lowering then refuses for that reason alone.
  def test_the_colors_description_leaves_a_game_the_room_its_lowering_leaves
    left = room_left_by_least_game

    assert_operator COLOR.free_work_memory_bytes, :<=, left
    assert_operator COLOR.free_work_memory_bytes, :>, left - 64, "the description gives away more than it needs to"
  end

  private def room_left_by_least_game
    memory = Memory.new
    lowering = GBC::Lowering.new(program(loop_(wait_vblank), console: :gbc), memory: memory)
    GBC::Runtime.reserve(memory, art: lowering.art, effects: lowering.music.effects,
                                 together: lowering.groups_up_together?)
    (Memory::LOW_END - Memory::FIRST) + (Memory::HIGH_END - Memory::HIGH_START) - memory.used
  end

  # The build check counts what the runtime keeps for a feature of the game before anything is
  # lowered (ColorKit#work_memory_reserved); the lowering's own memory is the answer key. A small
  # game with the feature and the same game without it differ by what the kit says. Each feature
  # is the bodies of the two games, without it and then with it, their loops included.
  private def kit_features
    plain = proc { game_loop {} }
    tiles = proc do
      colors :ball, %i[transparent red green white]
      image :art, width: 8, height: 16, colors: :ball, places: [1] * 128
      set = sprite_tiles :ball_tiles, count: 1, colors: :ball
      image :ball, tiles_from: :ball_tiles, pieces: [[0, 0, 0]]
      sprite :ball, at: [40, 40]
      set
    end
    recording = proc do
      enable_sound
      sample :boom, pcm: [40, -40] * 400, rate: 8000
    end
    {
      "a fade" => [plain, proc { game_loop { fade :black, 50 } }],
      "a tint" => [plain, proc { game_loop { tint :red, 50 } }],
      "a load of sprite tiles" => [proc { instance_exec(&tiles); game_loop {} },
                                   proc { set = instance_exec(&tiles); game_loop { set.copy_from :art, at: 1, count: 1, to: 0 } }],
      "a recording played once" => [proc { instance_exec(&recording); game_loop {} },
                                    proc { boom = instance_exec(&recording); game_loop { boom.play if pressed(:a) } }],
      "a recording played round" => [proc { instance_exec(&recording); game_loop {} },
                                     proc { boom = instance_exec(&recording); game_loop { boom.play(loop: true) if pressed(:a) } }],
      "the motor" => [plain, proc { game_loop { rumble frames: 12 if pressed(:a) } }],
    }
  end

  private def memory_used_by(body)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      instance_exec(&body)
    end
    b.finalize_program
    program = b.program
    memory = Memory.new
    lowering = GBC::Lowering.new(program, memory: memory)
    # The flags the backend hands the runtime for these features (GBC#lower).
    GBC::Runtime.reserve(memory, art: lowering.art, effects: lowering.music.effects,
                                 together: lowering.groups_up_together?, walks_colors: lowering.walks_colors?,
                                 tile_loads: lowering.loads_sprite_tiles?, clips: lowering.clips.any?,
                                 clip_laps: lowering.clips.loops?, rumble: lowering.rumbles?)
    [memory.used, VBlank::Console.for(:gbc).work_memory_reserved(program).sum(&:bytes)]
  end

  def test_the_kits_count_of_what_the_runtime_keeps_matches_the_lowerings_memory
    kit_features.each do |name, (without_body, with_body)|
      without, nothing = memory_used_by(without_body)
      used, kit_bytes = memory_used_by(with_body)

      assert_equal 0, nothing, "the game without #{name} is counted nothing"
      assert_operator kit_bytes, :>, 0, name
      assert_equal used - without, kit_bytes, "the runtime keeps #{used - without} bytes for #{name}"
    end
  end

  # A table read with its page in one register sits in one page: first, at the first place with
  # nothing lost; later, moved up to the next page rather than across one.
  def test_a_place_in_one_page_never_crosses_a_page
    memory = Memory.new
    first = memory.reserve_in_page("first table", 96)
    memory.reserve("a list", 300)
    later = memory.reserve_in_page("later table", 96)

    assert_equal Memory::FIRST, first
    assert_equal later >> 8, (later + 95) >> 8
    assert_operator later, :>=, Memory::FIRST + 96 + 300
  end

  # What the check cannot see, the runtime's own state, can still fill the room, so the lowering
  # refuses too, in words the author can act on.
  def test_a_list_past_the_room_left_is_refused_in_plain_words
    memory = Memory.new
    memory.reserve("the list :rocks", 3 * 1024)
    memory.reserve("the list :stones", 4000)

    error = assert_raises(Memory::Full) { memory.reserve("the list :trail", 2 * 1024) }

    assert_match(/Game Boy Color's work memory/, error.message)
    assert_match(/The list :trail needs 2048 bytes/, error.message)
    assert_match(/smaller capacities/, error.message)
  end
end
