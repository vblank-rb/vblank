# frozen_string_literal: true

require "test_helper"

# WHAT THE RUBY RUNTIME ALLOCATES A PASS. Every object a pass makes, and every byte of memory one
# takes, is work for Ruby's garbage collector: memory taken counts toward the next collection as
# objects do, and enough of it makes Ruby mark every object the process holds, which in a big game
# stops it for several frames. Two ways a busy game took a lot: a slice of one of the screen's arrays
# shares the array's storage, so the next write to the array copies the whole screen's worth of it
# first; and a fade or tint set again the same every pass made its table of colours again, an Array
# with a place for every colour. The counts are of ten more passes, exact where a time is not; the
# picture is held to the interpreter by the tests this run plays.
class TestRubyObjectsAPass < Minitest::Test
  SCREEN_ROWS = 160
  SCREEN_PIXELS = 240 * 160

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
    (allocated_playing(program, 12) - allocated_playing(program, 2)) / 10
  end

  # A field that scrolls every pass, so the picture is new every pass, under a tint when +tinted+,
  # and the tint set again every pass when +tinted_every_pass+.
  private def scrolling_field(tinted: false, tinted_every_pass: false)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
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
    b.finalize_program
    b.program
  end

  private def assert_allocates_little(program)
    a_pass = allocated_a_pass(program)
    assert_operator a_pass.objects, :<, SCREEN_ROWS / 4, "objects allocated a pass"
    assert_operator a_pass.bytes, :<, SCREEN_PIXELS, "bytes of memory taken a pass"
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
end
