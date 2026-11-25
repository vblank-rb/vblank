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
  # lowered (GBC::WorkReservations); the lowering's own memory is the answer key. A small game with
  # the feature and the same game without it differ by what the check counts. Each feature is the
  # bodies of the two games, without it and then with it, their loops included.
  private def kit_features
    plain = proc { game_loop {} }
    tile_set = proc do
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
    cells = proc do
      image(:cell, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :cells, "#" => :cell, "." => :cell
    end
    bar = proc do
      instance_exec(&cells)
      status_bar :score, tiles: :cells, map: ["#" * 20] * 2, top: screen_height - 16
    end
    field = proc do
      instance_exec(&cells)
      background :field, tiles: :cells, map: Array.new(18) { "#" * 20 }
    end
    {
      "a fade" => [plain, proc { game_loop { fade :black, 50 } }],
      "a tint" => [plain, proc { game_loop { tint :red, 50 } }],
      "a load of sprite tiles" => [proc { instance_exec(&tile_set); game_loop {} },
                                   proc { set = instance_exec(&tile_set); game_loop { set.copy_from :art, at: 1, count: 1, to: 0 } }],
      "a recording played once" => [proc { instance_exec(&recording); game_loop {} },
                                    proc { boom = instance_exec(&recording); game_loop { boom.play if pressed(:a) } }],
      "a recording played round" => [proc { instance_exec(&recording); game_loop {} },
                                     proc { boom = instance_exec(&recording); game_loop { boom.play(loop: true) if pressed(:a) } }],
      "the motor" => [plain, proc { game_loop { rumble frames: 12 if pressed(:a) } }],
      "the frames the screen is off" => [proc { count = var :count, 0; game_loop { count += 1 } },
                                         proc { count = var :count, 0; game_loop { count = frames_since_power_on } }],
      "a status bar" => [proc { instance_exec(&cells); game_loop {} }, proc { instance_exec(&bar); game_loop {} }],
      "a status bar covering the sprites" => [proc { instance_exec(&bar); game_loop {} },
                                              proc { score = instance_exec(&bar); game_loop { score.covers_sprites = true if pressed(:a) } }],
      "a cell shown now" => [proc { f = instance_exec(&field); game_loop { f.set_tile 1, 1, "." } },
                             proc { f = instance_exec(&field); game_loop { f.set_tile 1, 1, ".", now: true } }],
      "a song that plays once" => [music_game { |song| song },
                                   music_game { |song| song.with(plays_once: true) }],
      "a song whose notes wobble" => [music_game { |song| song },
                                      music_game { |song| song.with(parts: song.parts.map { |part| part.with(vibrato: { depth: 4 }) }) }],
      "music held" => [music_game { |song| song }, music_game(hold: true) { |song| song }],
      "a sound effect" => [music_game { |song| song }, music_game(effect: true) { |song| song }],
    }
  end

  # A game that plays one square note as a song, made from a plain one by the block, and holds
  # its music or plays the same notes as a sound effect where asked.
  private def music_game(hold: false, effect: false, &song_of)
    score = VBlank::Audio::Score
    song = song_of.call(score.new(tempo: 150, length: 20,
                                  parts: [score::Part.new(notes: [score::Note.new(at: 0, key: :C5)])]))
    proc do
      enable_sound
      music = songs :music, [song]
      effects = sound_effects :blips, [song] if effect
      game_loop do
        music.play 0
        hold_music if hold && pressed(:a)
        effects.play 0 if effect && pressed(:b)
      end
    end
  end

  # What a build of the game the body makes reserves in work memory, the runtime handed what the
  # backend hands it (GBC#lower, with the songs and effects in view), and what the check counts.
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
    music = lowering.music
    GBC::Runtime.reserve(memory, art: lowering.art, effects: music.effects, together: lowering.groups_up_together?,
                                 bar_rows: lowering.bar_rows, slides: music.slides?, pans: music.pans?,
                                 wobbles: music.wobbles?, shapes: music.shapes?, waves: music.waves?,
                                 swells: lowering.holds_swells?, noise_swells: lowering.holds_noise_swells?,
                                 clips: lowering.clips.any?, clip_laps: lowering.clips.loops?,
                                 dark: lowering.counts_dark_frames?, rumble: lowering.rumbles?,
                                 kept_sprites: lowering.keeps_unchanged_sprites?, holds_music: lowering.holds_music?,
                                 tune_plays_once: music.tune_plays_once?, effect_clock_step: music.effect_clock_step,
                                 cells_shown_now: lowering.cells_shown_now?, bar_covers: lowering.bar_covers_sprites?,
                                 tile_loads: lowering.loads_sprite_tiles?, walks_colors: lowering.walks_colors?,
                                 grids_kept: lowering.reserves_grid_kept?)
    [memory.used, VBlank::Console.for(:gbc).work_memory_reserved(program).sum(&:bytes)]
  end

  def test_the_checks_count_of_what_the_runtime_keeps_matches_the_lowerings_memory
    kit_features.each do |name, (without_body, with_body)|
      without, counted_without = memory_used_by(without_body)
      used, counted = memory_used_by(with_body)

      assert_operator used, :>, without, "the runtime keeps something for #{name}"
      assert_equal used - without, counted - counted_without, "the runtime keeps #{used - without} bytes for #{name}"
    end
  end

  # A place too big for what is left of the always-there half goes in the banked half, and a
  # smaller one asked for after it still fits in the always-there half: its room is not lost.
  def test_a_smaller_place_after_one_that_went_to_the_banked_half_fills_the_always_there_half
    memory = Memory.new
    big = memory.reserve("a big list", (Memory::LOW_END - Memory::FIRST) + 1)
    small = memory.reserve("a small list", 100)

    assert_operator big, :>=, Memory::HIGH_START
    assert_equal Memory::FIRST, small
    assert memory.banked_half_used?
  end

  # The check and the lowering stop at one size. Two lists, each half of +bytes+ of word slots:
  # the largest the check passes builds, and the next size up is refused by the check, never by
  # the lowering alone.
  private def two_lists(bytes)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      trail = list :trail, capacity: bytes / 8
      tail = list :tail, capacity: bytes / 8
      game_loop do
        trail.push 100_000
        tail.push 200_000
      end
    end
    b.finalize_program
    b.program
  end

  private def checked?(program)
    checks = VBlank::IR::Guardrails::Validator.new(checks: [VBlank::IR::Guardrails::Checks::IwramBudget.new])
    checks.run(program, autofix: false).findings.none?(&:error?)
  end

  def test_the_largest_two_lists_the_check_passes_build_and_the_next_are_refused_by_it
    passed = (0..(COLOR.free_work_memory_bytes / 8)).bsearch { |eighths| !checked?(two_lists((eighths + 1) * 8)) } * 8

    VBlank::Console.for(:gbc).builder.cartridge_for(two_lists(passed), title: "LISTS")
    refute checked?(two_lists(passed + 8)), "the next size up is refused by the check"
    assert_operator passed, :>, COLOR.largest_list_bytes, "the two lists share both halves"
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
