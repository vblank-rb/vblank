# frozen_string_literal: true

require "test_helper"

# WHAT THE COLOURS OF A BACKGROUND THAT WALKS BETWEEN AREAS COST.
#
# The gap between frames is the routine every frame runs, and the first thing kept in the
# console's quick memory. Each group a borrowed list (`draw_with`) sits in is written by the
# borrow, and written again whenever an area's or a scene's colours go in over it. Written out in
# the gap for each group, a house of many borrowed lists grew the gap by kilobytes and pushed the
# routines a frame runs out of the quick memory.
#
# And two backgrounds that walk change area together and read one table. Each sent the area's
# whole table through the tint, and every borrowed group after it, so the pass two layers walked
# into a house on was as long again as bringing their tiles in, and a big game missed that frame.
class TestWalkingColorsCost < Minitest::Test
  STRIPE = Array.new(64) { |i| (i % 8) < 4 ? 1 : 2 }.freeze

  # A title, then a scene whose background walks from a field into a house of +lists+ lists. With
  # +borrow+ the house is drawn with dark lists, and then with its own again.
  private def walking_game(lists:, borrow:)
    keys = ("a".."z").first(lists)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :field, %i[transparent green white]
      image :grass, width: 8, height: 8, colors: :field, places: STRIPE
      tiles :field_tiles, "g" => :grass
      lists.times do |n|
        colors :"house#{n}", [:transparent, Color.rgb(n * 2, 0, 31), Color.rgb(31, n * 2, 0)]
        colors :"dark#{n}", [:transparent, Color.rgb(0, n * 2, 8), Color.rgb(8, 0, n * 2)]
        image :"floor#{n}", width: 8, height: 8, colors: :"house#{n}", places: STRIPE
      end
      tiles :house_tiles, keys.each_with_index.to_h { |key, n| [key, :"floor#{n}"] }
      tick = var :tick, 0
      room = var :room, 0
      state = var :state, 0
      scene(:title) { state = 1 if tick == 1 }
      scene(:play) do
        ground = background :ground, tiles: { field: :field_tiles, house: :house_tiles },
                                     map: { field: { meadow: Array.new(20) { "g" * 30 } },
                                            house: { hall: Array.new(20) { (keys.join * 30)[0, 30] } } }
        room = 1 if tick == 3
        if borrow
          ground.draw_with(lists.times.to_h { |n| [:"house#{n}", :"dark#{n}"] }) if tick == 4
          ground.draw_with :own if tick == 5
        end
        ground.show_map room
      end
      game_loop do
        tick += 1
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    builder.finalize_program
    builder.program
  end

  private def rom_of(program, title)
    backend = GBA.new
    ROM.assemble(backend.lower(program), title: title, built: backend.build_record(program))
  end

  # Bytes of the routine every frame runs.
  private def frame_bytes(program)
    rom_of(program, "WALKCOLOR").built.routines.fetch(VBlank::Cartridge::BuildRecord::FRAME_ROUTINE).size
  end

  # What the borrow adds to that routine in a house of +lists+ lists.
  private def borrow_bytes(lists) = frame_bytes(walking_game(lists: lists, borrow: true)) -
                                    frame_bytes(walking_game(lists: lists, borrow: false))

  # Room for a branch or two that differs; nothing like a group's walk.
  SLACK = 32

  def test_the_gap_a_borrow_adds_to_does_not_grow_with_the_lists_borrowed
    few = borrow_bytes(2)
    many = borrow_bytes(8)

    assert_operator many - few, :<=, SLACK,
                    "a borrow of 2 lists added #{few} bytes to the gap, and of 8 lists #{many}"
  end

  # +layers+ backgrounds that walk together from a field into a house of eight lists, on the
  # tenth pass, under a tint held from the start so that every table sent is walked colour by
  # colour. The first layer borrows the house's lists as it goes in.
  private def layers_walking(layers)
    names = %i[ground scenery].first(layers)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      colors :field, %i[transparent green white]
      image :grass, width: 8, height: 8, colors: :field, places: STRIPE
      tiles :field_tiles, "g" => :grass
      8.times do |n|
        colors :"house#{n}", [:transparent, Color.rgb(n * 2, 0, 31), Color.rgb(31, n * 2, 0)]
        colors :"dark#{n}", [:transparent, Color.rgb(0, n * 2, 8), Color.rgb(8, 0, n * 2)]
        image :"floor#{n}", width: 8, height: 8, colors: :"house#{n}", places: STRIPE
      end
      tiles :house_tiles, ("a".."h").each_with_index.to_h { |key, n| [key, :"floor#{n}"] }
      walking = names.map do |name|
        background name, tiles: { field: :field_tiles, house: :house_tiles },
                         map: { field: { meadow: Array.new(20) { "g" * 30 } },
                                house: { hall: Array.new(20) { ("a".."h").to_a.join * 4 }.map { _1[0, 30] } } }
      end
      tick = var :tick, 0
      room = var :room, 0
      game_loop do
        tick += 1
        tint :black, 50 if tick == 1
        room = 1 if tick == 10
        walking.first.draw_with(8.times.to_h { |n| [:"house#{n}", :"dark#{n}"] }) if tick == 10
        walking.each { |layer| layer.show_map room }
      end
    end
    builder.finalize_program
    builder.program
  end

  # Instructions spent in each routine that brings a set in, over the frames from power-on.
  private def set_swap_work(program)
    rom = rom_of(program, "WALKTWO")
    lines = VBlank::Diagnostics::Profiler.run(rom, frames: 30, settle: 0, picture: false, split_hints: false).lines
    lines.to_h { |line| [line.name, line.samples] }
  end

  # Most of what bringing a set in costs the processor is the area's colours: its tiles and map
  # are copies, which the console makes with the processor stopped. So the second layer in,
  # which finds the colours up, costs a small part of what the first does.
  def test_a_second_layer_walking_into_an_area_sends_no_colours
    require_emulator!
    work = set_swap_work(layers_walking(2))
    first = work.fetch(:__set_swap_ground)
    second = work.fetch(:__set_swap_scenery)

    assert_operator second * 10, :<, first, "the first layer in took #{first} instructions, and the second #{second}"
  end
end
