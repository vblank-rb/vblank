# frozen_string_literal: true

require "test_helper"

# WHAT PUTTING A LAYER'S BORROWED COLOURS BACK COSTS A TINT. A tint walks the whole colour table
# from the cartridge, and a layer drawing from a borrowed list has those groups written again after
# it (PaletteTint#emit_recolored_banks). Here a background walks from a field into a house, and the
# house borrows six lists at once and gives them back.
#
# Two costs, each of which made a game run late. Written out at every tint, those six groups were
# most of the code of a game that tints in several places, and pushed the frame's routine out of
# the console's quick memory. And once the house had given its lists back, every tint still wrote
# its six groups again, from colours that were the ones already there.
class TestRecoloredBanksCost < Minitest::Test
  STRIPE = Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }.freeze
  LISTS = 6
  TILE_KEYS = ("a".."f").to_a.freeze

  # A field and a house of LISTS lists. With +borrow+ the house is drawn with dark lists on the
  # third pass and with its own again on the fourth. +each+ runs on every pass, given the pass.
  private def walking_game(borrow:, &each)
    lists = LISTS
    keys = TILE_KEYS
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :field, %i[transparent green white]
      image :grass, width: 8, height: 8, colors: :field, places: STRIPE
      lists.times do |n|
        colors :"house#{n}", [:transparent, Color.rgb(n * 4, 0, 31), Color.rgb(31, n * 4, 0)]
        colors :"dark#{n}", [:transparent, Color.rgb(0, n * 4, 8), Color.rgb(8, 0, n * 4)]
        image :"floor#{n}", width: 8, height: 8, colors: :"house#{n}", places: STRIPE
      end
      tiles :field_tiles, "g" => :grass
      tiles :house_tiles, keys.each_with_index.to_h { |key, n| [key, :"floor#{n}"] }
      ground = background :ground, tiles: { field: :field_tiles, house: :house_tiles },
                                   map: { field: { meadow: Array.new(20) { "g" * 30 } },
                                          house: { hall: Array.new(20) { keys.join * 5 } } }
      tick = var :tick, 0
      room = var :room, 0
      game_loop do
        tick += 1
        room = 1 if tick == 2
        if borrow
          ground.draw_with(lists.times.to_h { |n| [:"house#{n}", :"dark#{n}"] }) if tick == 3
          ground.draw_with :own if tick == 4
        end
        instance_exec(tick, &each)
        ground.show_map room
      end
    end
    builder.finalize_program
    builder.program
  end

  # Bytes of the whole cartridge's code.
  private def code_bytes(program) = GBA.new.lower(program).bytesize

  # A tint each pass, told something new every time, so every pass walks the table.
  TINT_EVERY_PASS = lambda do |tick|
    tint :red, 10 if (tick & 1) == 0 # rubocop:disable Style/NumericPredicate -- a game's number has no zero?
    tint :red, 20 if (tick & 1) == 1
  end

  # +count+ tints, each in a place of its own.
  private def tints(count) = ->(tick) { count.times { |n| tint :red, (n + 1) * 5 if tick == 10 + n } }

  # What each tint written in one more place adds to the code.
  private def bytes_per_tint(borrow:)
    (code_bytes(walking_game(borrow: borrow, &tints(5))) - code_bytes(walking_game(borrow: borrow, &tints(1)))) / 4
  end

  # One call and no more.
  CALL_BYTES = 16

  def test_a_tint_written_in_one_more_place_adds_a_call_for_borrowed_colours
    assert_operator bytes_per_tint(borrow: true), :<=, bytes_per_tint(borrow: false) + CALL_BYTES
  end

  # Instructions a frame: every game here keeps up, so the count reads the right way round.
  private def per_frame(program)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: "RECOLOR", built: backend.build_record(program))
    VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).samples_per_frame
  end

  # Next to nothing beside a walk of the table: the checks that find nothing borrowed.
  CHEAP = 200

  def test_a_tint_after_the_colours_are_given_back_costs_what_it_did_before
    require_emulator!
    given_back = per_frame(walking_game(borrow: true, &TINT_EVERY_PASS))
    never = per_frame(walking_game(borrow: false, &TINT_EVERY_PASS))

    assert_operator given_back - never, :<, CHEAP
  end
end
