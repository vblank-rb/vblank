# frozen_string_literal: true

require "test_helper"

# A COLOR GAME THAT KEEPS ADDING SCREENS AND SONGS (GBC#build_cartridge, indexes_in_banks). The part
# of a Color cartridge always in view holds 16384 bytes, the framework's own code among them. A game
# that fits there no other way keeps in the banks, too, the small tables that say where each thing
# is: each song's entry, where each sprite picture's pieces and outline are, each screen's tiles and
# colour lists, and each list of routines a call picks from. Then a song or a screen more costs
# nothing in view that grows with the song's length or the number of screens.
class TestGBCIndexesInBanks < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  PITCHES = %i[C4 D4 E4 F4 G4 A4 B4 C5 D5 E5 F5 G5].freeze

  # An 8×8 tile drawn in all four places of its list: a quarter of the tile each.
  QUARTERS = Array.new(64) { |i| 1 + ((i % 8) / 4) + (2 * ((i / 8) / 4)) }.freeze

  # Lists of colours each screen's background draws from, of its own: seven, beside the black one
  # every screen keeps first.
  BACKGROUND_LISTS = 7

  # Sprites on every screen, each in a list of colours of that screen's own.
  SHIPS = 8

  # Frames each screen stays up before the next takes over.
  SCREEN_FRAMES = 16

  # +count+ short effects, two notes each and all different.
  private def effects(count)
    score = VBlank::Audio::Score
    (0...count).to_h do |n|
      notes = [score::Note.new(at: 0, key: PITCHES[n % 12], length: 3 + (n % 5)),
               score::Note.new(at: 8, key: PITCHES[(n * 5) % 12], length: 3)]
      [:"zap#{n}", score.new(tempo: 120, parts: [score::Part.new(notes: notes)])]
    end
  end

  # A game of +screens+ scenes, each its own background of BACKGROUND_LISTS lists of colours and
  # SHIPS sprites in lists of its own; +songs+ songs of +notes+ sixteenths on two voices; and
  # +effect_count+ sound effects. The game loop moves to the next screen every SCREEN_FRAMES frames,
  # starts the second song, plays an effect, and calls one of two routines picked by number.
  private def many_screens(screens: 30, songs: 64, notes: 64, effect_count: 30)
    pitches = PITCHES
    quarters = QUARTERS
    sounds = effects(effect_count)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      enable_sound
      sfx = sound_effects :sfx, sounds
      songs.times do |s|
        song :"tune#{s}" do
          tempo 240
          voice(:lead) { |v| notes.times { |n| v.note pitches[(n + s) % 12], :sixteenth } }
          voice(:harmony) { |v| notes.times { |n| v.note pitches[((n * 5) + s) % 12], :sixteenth } }
        end
      end
      ships = (0...SHIPS).map do |n|
        colors :"ship#{n}", [:transparent, rgb(31, n * 3, 0), rgb(0, n * 3, 31)]
        image :"ship#{n}", width: 8, height: 8, colors: :"ship#{n}", places: Array.new(64) { |i| 1 + (i % 2) }
        sprite :"ship#{n}", at: [8 + (n * 16), 40], facing: { ship: :"ship#{n}" }
      end
      screens.times do |s|
        SHIPS.times do |n|
          shade = s % 32
          colors :"bg#{s}_#{n}", [:transparent, rgb(shade, n * 3, 31 - shade), rgb(31 - n, shade, n),
                                  rgb(n * 2, 31 - shade, shade), rgb(shade, shade, n)]
          image :"tile#{s}_#{n}", width: 8, height: 8, colors: :"bg#{s}_#{n}", places: quarters
          colors :"ship#{s}_#{n}", [:transparent, rgb(shade, n * 3, 9), rgb(9, shade, n * 3)]
        end
        tiles :"set#{s}", (0...SHIPS).to_h { |n| [n.to_s, :"tile#{s}_#{n}"] }
      end
      showing = var :showing, 0
      tick = var :tick, 0
      hits = var :hits, 0
      func(:hit_low) { hits += 1 }
      func(:hit_high) { hits += 3 }
      screens.times do |s|
        scene :"screen#{s}" do
          background :"field#{s}", tiles: :"set#{s}", map: Array.new(18) { (0...BACKGROUND_LISTS).map(&:to_s).join * 2 }
          ships.each_with_index { |ship, n| ship.draw_with :"ship#{s}_#{n}" }
        end
      end
      game_loop do
        tick += 1
        play_song :tune1 if tick == 2
        sfx.play :zap3 if tick == 4
        call %i[hit_low hit_high], number: tick % 2
        showing = (showing + 1) % screens if (tick % SCREEN_FRAMES) == 0
        case_var(:showing) { screens.times { |s| when_val s, :"screen#{s}" } }
      end
    end
    b.finalize_program
    b.program
  end

  # The bytes of the part always in view the game takes: up to the last that is not the blank a
  # cartridge is filled with.
  private def bytes_in_view(program)
    GBC.new.build(program).bytes.byteslice(0, 0x4000).sub(/\xFF+\z/n, "").bytesize
  end

  def test_a_game_past_the_part_always_in_view_builds_with_its_indexes_in_the_banks
    code = GBC.new.build(many_screens).built.code

    assert_operator code.fetch("music_songs").bank, :>, 0, "the songs' entries in a bank"
    assert_operator code.fetch("art_pictures").bank, :>, 0, "where each picture is, in a bank"
    assert_operator code.fetch("art_rooms").bank, :>, 0, "each screen's tiles and colours, in a bank"
  end

  def test_a_game_past_the_part_always_in_view_plays_as_the_interpreter_plays_it
    game_player.run(many_screens, frames: (SCREEN_FRAMES * 4) + 6)
  end

  # Each screen brings eight lists of colours for its background and eight for its sprites, its
  # tiles and its map: none of it in view.
  def test_more_screens_cost_nothing_more_in_view
    assert_equal bytes_in_view(many_screens(screens: 26)), bytes_in_view(many_screens(screens: 30))
  end

  def test_longer_songs_cost_nothing_more_in_view
    assert_equal bytes_in_view(many_screens(notes: 64)), bytes_in_view(many_screens(notes: 96))
  end

  # A song more is its rank alone in view: a byte.
  def test_a_song_more_costs_a_byte_in_view
    assert_operator bytes_in_view(many_screens(songs: 64)) - bytes_in_view(many_screens(songs: 60)), :<=, 4
  end
end
