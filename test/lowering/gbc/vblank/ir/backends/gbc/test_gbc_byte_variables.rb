# frozen_string_literal: true

require "test_helper"
require "stringio"

# The variables the Color's lowering keeps in one byte though the game never said so
# (GBC::ByteVariables): every write to one is proven to give a number a byte holds, so the
# cartridge keeps it in that byte and reads it back with its sign, and the game's numbers are the
# interpreter's on every pass.
class TestGBCByteVariables < Minitest::Test
  include VBlank::IR::Build

  GBC = VBlank::IR::Backends::GBC

  # A list of links, as a pool keeps them, walked by numbers read from it; a counter held to a
  # list's capacity by the write it indexes; and variables whose writes prove nothing.
  def linked_program
    program(
      list_new(:links, 8, width: :byte, full_of: -1),
      list_new(:marks, 8, width: :byte, full_of: 0),
      set(:at, list_get(:links, 0)),
      set(:ahead, :at),
      set(:ahead, -1),
      set(:held, 3),
      clamp(:held, 0, 100),
      set(:big, 200),
      set(:follows_big, :big),
      set(:filled, 0),
      repeat(8, :turn,
             list_set(:marks, :filled, :turn),
             add(:filled, 1)),
      add(:drift, 1),
      set(:pair, :ahead),
      negate(:pair)
    )
  end

  def test_variables_proven_to_hold_a_byte_are_named
    names = GBC::ByteVariables.new(linked_program).names

    assert_equal %i[ahead at filled held turn], names.sort
  end

  def test_a_variable_with_a_write_not_proven_is_not_named
    names = GBC::ByteVariables.new(linked_program).names

    %i[big follows_big drift pair].each { |name| refute_includes names, name }
  end

  def test_a_variable_the_game_declared_narrow_is_left_as_declared
    builder = Builder.new
    builder.instance_eval do
      small = var :small, 0, width: :half
      game_loop { small = 5 }
    end
    builder.finalize_program

    refute_includes GBC::ByteVariables.new(builder.program).names, :small
  end

  def test_the_cartridge_keeps_a_proven_variable_in_one_byte_and_an_unproven_one_in_four
    built = GBC.new.build(program(*linked_program.children, halt)).built

    assert_equal 1, built.variable_bytes(:at)
    assert_equal 4, built.variable_bytes(:big)
  end

  # The music's level is only ever 0 to 16, but the runtime's player reads it where it is kept,
  # all four bytes (rt_music_level): kept in one, it would read the next variable's bytes too. A
  # variable whose place the lowering hands over (Lowering#place_of) is kept whole however
  # narrow it is proven, so a number written beside it changes nothing the music plays.
  def test_a_variable_the_runtime_reads_where_it_is_kept_stays_whole
    builder = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    builder.instance_eval do
      screen :bitmap
      enable_sound
      song :hold do
        tempo 60
        volume 12
        note :C4, :whole
      end
      music_volume 100
      after = 0
      pass = 0
      game_loop do
        after = 300
        pass += 1
        play_song :hold if pass == 1
        music_volume 50 if pass == 3
      end
    end
    builder.finalize_program

    assert_equal 4, GBC.new.build(builder.program).built.variable_bytes(VBlank::IR::Tunes::LEVEL)
    GBC::CheckedRun.new.run(builder.program, frames: 20)
  end

  # Every place a variable is kept is asked for by Lowering#place_of (whole) or
  # KeptVariables#kept_place_of (the bytes it is kept in), never read from the lowering's table
  # of places, so no new way of handing a variable over can skip the rule above.
  def test_the_color_lowering_reaches_variable_places_only_through_place_of
    sources = Dir[VBlank.root.join("lib/vblank/ir/backends/gbc/**/*.rb").to_s] + [VBlank.root.join("lib/vblank/ir/backends/gbc.rb").to_s]
    reached = sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{File.basename(path)}:#{i + 1}: #{line.strip}" if line.match?(/@variables\b|\bvariables\[|\bvariables\.fetch/) && !line.strip.start_with?("#")
      end
    end
    allowed = [/@variables = \{\}/, /@variables\[name\] = @memory\.reserve/, /@variables\.fetch\(name\)/,
               /attr_reader :variables/, /@variables\.keys\.filter_map/, /def keeps_variable\?/]
    assert_empty reached.reject { |line| allowed.any? { |pattern| line.match?(pattern) } }
  end

  # A byte read back widened: -1 from a list of links, multiplied past a byte, is the
  # interpreter's -1000 on every pass.
  def test_a_walk_through_links_agrees_with_the_interpreter
    builder = Builder.new
    builder.instance_eval do
      links = list :links, capacity: 6, width: :byte
      [1, 2, 3, 4, 5, -1].each { |n| links.push n }
      at = 0
      seen = 0
      far = 0
      game_loop do
        seen = 0
        at = 0
        repeat 6 do
          seen += 1 if at >= 0
          at = links[at] if at >= 0
        end
        far = at * 1000
      end
    end
    builder.finalize_program
    run = GBC::CheckedRun.new.run(builder.program, frames: 6)

    assert_equal(-1000, run[:far])
    assert_equal 6, run[:seen]
  end
end
