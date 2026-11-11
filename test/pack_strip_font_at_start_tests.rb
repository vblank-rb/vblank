# frozen_string_literal: true

require "tmpdir"
require "made_up_original"

# A FONT CUT FROM A STRIP OF THE PACK'S PICTURES, ITS PACK LEFT OUT: a row of numerals as an
# original keeps it, one picture cut into a picture for each character. Built with
# `pack_at_start: true` and handed the pack file, the game shows what the all-in-one build shows.
# The answer key is the all-in-one build on the interpreter.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackStripFontAtStartTests
  include MadeUpOriginal

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The strip: eleven characters, each 4x6, cut from a slot of pixels that starts before it, so a
  # piece read from the wrong row or column of the slot shows. The made-up copy's bytes there
  # differ from each to the next.
  CHARACTERS = " 0123456789"
  PIECE_WIDTH = 4
  STRIP_WIDTH = CHARACTERS.length * PIECE_WIDTH
  STRIP_HEIGHT = 6
  STRIP_FIRST = 20
  ART_BYTES = STRIP_FIRST + (STRIP_WIDTH * STRIP_HEIGHT) + 16
  STRIP_COLORS = Array.new(256) { |place| ((place * 37) + 5) & 0x7FFF }

  SLOTS = [VBlank::Original::Slot.colors(:palette, at: PALETTE_AT, count: 16),
           VBlank::Original::Slot.pixels(:art, at: 0, count: ART_BYTES)].freeze

  # The frames the number is looked at after, each showing a different number.
  FRAMES = [1, 2, 4].freeze

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def strip_pack_file
    VBlank::Original::Pack.holding(SLOTS.to_h { |slot| [slot.name, slot.cut_from(COPY)] }, sha1: SHA1, build_version: "1").to_bytes
  end

  # A game of the made-up original's colours and a slot of its bytes as pixels, whose block (run
  # on the builder, handed the pack) declares a font; it then draws a number that changes every
  # pass, a fixed one and words in that font.
  private def strip_font_game(folder, options: VBlank::Cartridge::Options.new, &declares)
    from = original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      pack = data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.pixels :art, at: 0, count: ART_BYTES
      end
      instance_exec(pack, &declares)
      shown = var :shown, 7
      game_loop do
        clear_screen :blue
        draw_number shown, 10, 10, digits: 3, font: :numerals
        draw_number shown, 10, 30, digits: 4, leading_zeros: true, font: :numerals
        draw_number 905, 10, 50, digits: 3, font: :numerals
        draw_text "31 20", 60, 50, font: :numerals
        shown.store!(shown + 148)
      end
    end
    b.finalize_program
    b.program
  end

  private def assert_strip_font_plays_alike(what, &declares)
    Dir.mktmpdir do |folder|
      whole = strip_font_game(folder, &declares)
      left_out = strip_font_game(folder, options: LEFT_OUT, &declares)

      FRAMES.each do |frames|
        shown = game_player.run(whole, frames: frames).screen.to_a
        assert_operator shown.flatten.uniq.length, :>, 4, "#{what}: the all-in-one build draws the numerals in their colours"
        handed = game_player.hand_file(strip_pack_file).run(left_out, frames: frames).screen.to_a
        # A count, not the two screens: a number drawn empty differs in every pixel of every digit.
        differing = shown.flatten.zip(handed.flatten).count { |whole_pixel, handed_pixel| whole_pixel != handed_pixel }
        assert_equal 0, differing, "#{what}: after #{frames} frames the game handed its pack shows #{differing} pixels " \
                                   "the all-in-one build does not"
      end
    end
  end

  def test_a_strip_of_pack_pixels_read_at_start_draws_as_the_all_in_one_build
    assert_strip_font_plays_alike("a strip of pixels") do |pack|
      image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS,
                            places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
      font :numerals, strip: :numeral_strip, characters: CHARACTERS
    end
  end

  def test_a_strip_of_pack_pixels_with_a_see_through_place_read_at_start_draws_as_the_all_in_one_build
    see_through = COPY.getbyte(STRIP_FIRST + 5)

    assert_strip_font_plays_alike("a strip with a see-through place") do |pack|
      image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS, see_through: see_through,
                            places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
      font :numerals, strip: :numeral_strip, characters: CHARACTERS
    end
  end

  # A strip whose places the game holds and whose colours are the pack's: the pieces are cut from
  # the places, and each reads the colours the strip reads.
  def test_a_strip_in_pack_colors_read_at_start_draws_as_the_all_in_one_build
    places = Array.new(STRIP_WIDTH * STRIP_HEIGHT) { |at| ((at * 7) + (at / STRIP_WIDTH)) % 16 }

    assert_strip_font_plays_alike("a strip in the pack's colours") do |pack|
      image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: pack[:palette], places: places
      font :numerals, strip: :numeral_strip, characters: CHARACTERS
    end
  end

  # A turned strip's pieces are not runs of the slot's rows, so the build says so rather than
  # drawing them empty.
  def test_a_turned_strip_of_pack_pixels_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        strip_font_game(folder, options: LEFT_OUT) do |pack|
          image :numeral_strip, width: STRIP_WIDTH, height: STRIP_HEIGHT, colors: STRIP_COLORS,
                                places: pack[:art].pixels(STRIP_FIRST, STRIP_WIDTH * STRIP_HEIGHT)
          font :numerals, strip: mirror(:numeral_strip), characters: CHARACTERS
        end
      end

      assert_includes error.message, "numeral_strip_mirrored"
      assert_includes error.message, "pictures:"
    end
  end
end
