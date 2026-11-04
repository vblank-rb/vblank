# frozen_string_literal: true

require "test_helper"
require "stringio"

# A GAME THAT FILLS THE FIRST 8K OF WORK RAM. The runtime keeps its state there, the sound effects'
# most of all, and the game's variables after it. When they do not all fit, the runtime's tables
# (the sound's queue and log, the cells waiting for the blank) go further on first, then the
# variables the game names least. The game plays as the interpreter plays it on a plain cartridge
# and on a Super FX one, and only a game whose sound effects fill the first 8K on their own is
# refused.
class TestSNESCrowdedWorkRAM < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  KEYS = %i[C5 D5 E5 F5 G5 A5 B5].freeze

  # +effects+ sound effects, one asked for on each pass in turn, and +variables+ numbers, a few
  # of them busy every pass and +approaches+ of them stepping towards another; a bar as long as a
  # sum of them shows what the game worked out.
  def self.crowded(effects:, variables:, approaches: 0, variants: {})
    scores = Array.new(effects) do |i|
      Score.new(tempo: 150, priority: 10, parts: [Part.new(notes: [Note.new(at: 0, key: KEYS[i % KEYS.size], length: 2 + (i % 3))])])
    end
    VBlank.game("CROWDED", consoles: %i[gba snes], variants: variants) do
      enable_sound
      sfx = sound_effects :sfx, scores.each_with_index.to_h { |score, i| [:"effect#{i}", score] }
      many = Array.new(variables) { |i| var :"number#{i}", i }
      busy = var :busy, 0
      pass = var :pass, 0
      which = var :which, 0
      total = var :total, 0
      game_loop do
        pass += 1
        4.times { busy += 1 }
        which = pass % effects
        sfx.play which
        many[0] += 1
        many[variables - 1] += many[0] + busy
        total = many[variables - 1] - many[variables / 2]
        # Each `approach!` keeps a number of its own the game never named. A few a pass, in turn.
        many.first(approaches).each_slice(10).with_index do |slice, turn|
          slice.each { |number| number.approach!(busy, 3) } if pass % (approaches / 10) == turn
        end
        fill_rect 0, 0, 64, 8, :black
        draw_rect_at 0, 0, (total & 63) + 1, 8, :green
      end
    end
  end

  CROWDED = crowded(effects: 40, variables: 1300, approaches: 200)
  CROWDED_ON_CHIP = crowded(effects: 40, variables: 1300, approaches: 200, variants: { snes: :superfx })

  private def built(game) = SNES.new.build(game.program(console: :snes)).built

  def test_a_crowded_game_plays_as_the_interpreter_plays_it
    game_player.run(CROWDED.program(console: :snes), frames: 12)
  end

  def test_a_crowded_game_plays_as_the_interpreter_plays_it_on_a_super_fx_cartridge
    game_player.run(CROWDED_ON_CHIP.program(console: :snes, variant: :superfx), frames: 12)
  end

  # The runtime's tables go first, and the variables the game names most stay near.
  def test_the_tables_go_further_on_before_the_busy_variables
    places = built(CROWDED)

    assert_operator places.runtime.fetch(SNES::Runtime::Sound::QUEUE), :>, 0xFFFF
    assert_operator places.runtime.fetch(SNES::Runtime::Sound::LOG), :>, 0xFFFF
    assert_operator places.variables.fetch(:busy), :<, 0x10000
    assert_operator places.variables.fetch(:number900), :>, 0xFFFF
  end

  # A game with room keeps everything where it always was.
  def test_a_game_with_room_keeps_its_tables_near
    places = built(self.class.crowded(effects: 4, variables: 40))

    assert_operator places.runtime.fetch(SNES::Runtime::Sound::QUEUE), :<, 0x10000
    assert_operator places.variables.fetch(:number39), :<, 0x10000
  end

  def test_sound_effects_that_fill_the_first_8k_are_refused_in_plain_words
    error = assert_raises(SNES::LoweringError) { built(self.class.crowded(effects: 110, variables: 4)) }

    assert_match(/fewer sound effects/, error.message)
  end
end
