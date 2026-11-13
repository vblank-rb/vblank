# frozen_string_literal: true

require "test_helper"

# WHAT THE RUBY RUNTIME ALLOCATES A PASS. Every object a pass makes, and every byte of memory one
# takes, is work for Ruby's garbage collector: memory taken counts toward the next collection as
# objects do, and enough of it makes Ruby mark every object the process holds, which in a big game
# stops it for several frames. Ways a busy game took a lot: a slice of one of the screen's arrays
# shares the array's storage, so the next write to the array copies the whole screen's worth of it
# first; a fade or tint made its table of colours again each time it was set, an Array with a place
# for every colour; and each frame's sound was written into new Arrays. The counts are of ten more
# passes, exact where a time is not; the picture and the sound are held to the interpreter by the
# tests this run plays.
class TestRubyObjectsAPass < Minitest::Test
  MOST_OBJECTS_A_PASS = 40
  # Less than one speaker's frame of sound at the slowest rate a console mixes at, kept as Ruby numbers.
  MOST_BYTES_A_PASS = 1024

  Allocated = Data.define(:objects, :bytes) do
    def -(other) = Allocated.new(objects - other.objects, bytes - other.bytes)
    def /(other) = Allocated.new(objects / other, bytes / other)
  end

  # What playing +frames+ allocates. Collection is held off while it plays, so the memory Ruby
  # counts toward the next one is not set back to nought part way.
  private def allocated_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    GC.start
    GC.disable
    objects = GC.stat(:total_allocated_objects)
    bytes = GC.stat(:malloc_increase_bytes)
    game.play(player)
    Allocated.new(GC.stat(:total_allocated_objects) - objects, GC.stat(:malloc_increase_bytes) - bytes)
  ensure
    GC.enable
  end

  # What one more pass allocates, with what starting the game allocates taken away.
  private def allocated_a_pass(program)
    (allocated_playing(program, 22) - allocated_playing(program, 2)) / 20
  end

  private def built(&game)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval(&game)
    b.finalize_program
    b.program
  end

  # A field that scrolls every pass, so the picture is new every pass, under a tint when +tinted+,
  # and the tint set again every pass when +tinted_every_pass+.
  private def scrolling_field(tinted: false, tinted_every_pass: false)
    built do
      screen :tiled
      image(:field_art, "#" => :green, "." => :blue, "o" => :white) { (["#.o.#.o."] * 8).join("\n") }
      tiles :field_tiles, "a" => :field_art
      field = background :field, tiles: :field_tiles, map: Array.new(32) { "a" * 32 }
      across = var :across, 0
      tint :red, 30 if tinted
      game_loop do
        across += 1
        field.scroll_to across, 0
        tint :red, 30 if tinted_every_pass
      end
    end
  end

  # The same field fading in and out, its amount moving every pass.
  private def fading_field
    built do
      screen :tiled
      image(:field_art, "#" => :green, "." => :blue, "o" => :white) { (["#.o.#.o."] * 8).join("\n") }
      tiles :field_tiles, "a" => :field_art
      background :field, tiles: :field_tiles, map: Array.new(32) { "a" * 32 }
      amount = var :amount, 0
      game_loop do
        amount += 7
        amount = 0 if amount > 100
        fade :black, amount
      end
    end
  end

  # A tune of the console's own voices, held long past the passes counted.
  private def tune
    built do
      screen :bitmap
      enable_sound
      song :tune do
        tempo 60
        voice(:lead) { note :C4, :whole }
        voice(:bass) { note :C3, :whole }
      end
      play_song :tune
      game_loop {}
    end
  end

  # A tune played on a recorded instrument, which the runtime mixes itself.
  private def recorded_tune
    built do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :tune do
        tempo 60
        voice(:lead, plays: :piano) { note :C4, :whole }
      end
      play_song :tune
      game_loop {}
    end
  end

  private def assert_allocates_little(program)
    a_pass = allocated_a_pass(program)
    assert_operator a_pass.objects, :<, MOST_OBJECTS_A_PASS, "objects allocated a pass"
    assert_operator a_pass.bytes, :<, MOST_BYTES_A_PASS, "bytes of memory taken a pass"
  end

  def test_a_scrolling_picture_allocates_little_a_pass
    assert_allocates_little(scrolling_field)
  end

  def test_a_tinted_scrolling_picture_allocates_little_a_pass
    assert_allocates_little(scrolling_field(tinted: true))
  end

  def test_a_picture_tinted_again_every_pass_allocates_little_a_pass
    assert_allocates_little(scrolling_field(tinted_every_pass: true))
  end

  def test_a_fade_that_moves_every_pass_allocates_little_a_pass
    assert_allocates_little(fading_field)
  end

  def test_a_tune_allocates_little_a_pass
    assert_allocates_little(tune)
  end

  def test_a_tune_on_a_recorded_instrument_allocates_little_a_pass
    assert_allocates_little(recorded_tune)
  end
end
