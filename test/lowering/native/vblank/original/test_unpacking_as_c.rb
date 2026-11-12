# frozen_string_literal: true

require "test_helper"
require "made_up_original"
require "pack_games"

# AN ALL-IN-ONE BUILD PLAYS A PORT'S UNPACKING THE FASTEST WAY THE MACHINE HAS
# (Original::Unpacking#run_fastest): as C where zig is installed, as Ruby where it is not. Whichever
# plays it, the pack is the one the interpreter writes, byte for byte. This run is the one sure to
# have zig, so the C is played here; every unpacking a test plays on it is also played to its end
# as C and held to the checked run (Testing::UnpackingPlayedToItsEnd).
class TestUnpackingAsC < Minitest::Test
  runs_on_the_main_ractor! # records the unpackings a build plays, and stubs the look for zig
  include MadeUpOriginal

  Unpacking = VBlank::Original::Unpacking
  Zig = VBlank::IR::Backends::Native::Zig
  PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true, console: :gba)
  STUCK_AFTER_SECONDS = 0.5
  RECORDING = :vblank_unpackings_recorded

  # Each unpacking an all-in-one build plays, kept while a test asks for them (#unpackings_built_by).
  module RecordsUnpackingsPlayed
    def run_fastest(...)
      Thread.current[RECORDING]&.push(self)
      super
    end
  end
  Unpacking.prepend(RecordsUnpackingsPlayed)

  # The unpackings the block's builds played.
  private def unpackings_built_by
    Thread.current[RECORDING] = []
    yield
    Thread.current[RECORDING]
  ensure
    Thread.current[RECORDING] = nil
  end

  # The pack +run+ wrote, as bytes: every slot, then the frame records.
  private def pack_in(unpacking, run) = [unpacking.slot_bytes_in(run).transform_values(&:b), unpacking.frame_records_in(run).b]

  # +unpacking+ played as C, as Ruby where the Ruby runtime plays it, and on the interpreter, each
  # held to the interpreter's pack.
  private def assert_one_pack_three_ways(unpacking, name)
    on_interpreter = unpacking.run_on(Reference.new, frames: unpacking.most_frames, max_steps: unpacking.most_steps_a_frame)
    wanted = pack_in(unpacking, on_interpreter)

    assert unpacking.finished_in?(on_interpreter), "#{name}: the unpacking finished on the interpreter"
    assert_equal wanted, pack_in(unpacking, unpacking.run_as_c(frames: unpacking.most_frames)), "#{name}: as C"
    begin
      as_ruby = unpacking.run_as_ruby(frames: unpacking.most_frames)
    rescue VBlank::IR::Backends::Ruby::RuntimeGap
      return
    end
    assert_equal wanted, pack_in(unpacking, as_ruby), "#{name}: as Ruby"
  end

  # Every registered pack game's all-in-one build, whose routine its build played, and the unpacking
  # of every game that keeps its data pack with its pack left out (the one a shell plays), each played
  # three ways.
  def test_every_registered_pack_games_unpacking_writes_the_interpreters_pack_as_c_and_as_ruby
    compared = PackGames::ALL.sum do |game|
      Dir.mktmpdir do |folder|
        left_out = nil
        played = unpackings_built_by do
          game.kit.new.build(game, folder, PackGames::ALL_IN_ONE)
          left_out = begin
            game.kit.new.build(game, folder, PackGames::LEFT_OUT)
          rescue ArgumentError, VBlank::BuildError
            nil
          end
        end
        if left_out&.data_pack
          copy = left_out.data_pack.original.copy
          played << left_out.data_pack.unpacking(release: left_out.data_pack.original.releases.with_sha1(copy.sha1))
                                     .with(copy_bytes: File.binread(copy.path))
        end
        played.each { |unpacking| assert_one_pack_three_ways(unpacking, game.name) }
        played.length
      end
    end

    assert_operator compared, :>, 0, "some registered game unpacks"
  end

  # Built with the pack left out, so the build does not play the routine itself and the test can.
  private def unpacking_of(folder, copy: "\0".b * COPY_SIZE, &routine)
    from = original(folder)
    unpacking = Builder.new(options: PACK_AT_START).instance_eval do
      data_pack(from: from, version: "1") do |slots|
        slots.tiles :walls, count: 2
        slots.fill_from_copy(&routine)
      end
    end.unpacking(release: VBlank::Original::Release.from("Test", { "sha1" => SHA1, "size" => COPY_SIZE }))
    unpacking.with(copy_bytes: copy)
  end

  private def copying_unpacking(folder)
    unpacking_of(folder, copy: COPY) do |copy, pack|
      repeat(TILE_BYTES.bytesize) do |at|
        pack[:walls][at] = copy.byte(TILES_AT + at)
        copy.count_written 1
      end
    end
  end

  def test_the_fastest_run_is_c_where_zig_is_installed
    Dir.mktmpdir do |folder|
      unpacking = copying_unpacking(folder)
      ran = unpacking.run_fastest

      assert_equal :c, ran.runner
      assert_equal TILE_BYTES, unpacking.slot_bytes_in(ran).fetch(:walls)
    end
  end

  # The block, played on a machine where Zig.installed? answers false.
  private def without_zig
    Zig.singleton_class.alias_method(:installed_on_this_machine?, :installed?)
    Zig.define_singleton_method(:installed?) { false }
    yield
  ensure
    Zig.singleton_class.alias_method(:installed?, :installed_on_this_machine?)
    Zig.singleton_class.remove_method(:installed_on_this_machine?)
  end

  def test_the_fastest_run_is_ruby_where_zig_is_not_installed
    Dir.mktmpdir do |folder|
      unpacking = copying_unpacking(folder)
      ran = without_zig { unpacking.run_fastest }

      assert_equal :ruby, ran.runner
      assert_equal TILE_BYTES, unpacking.slot_bytes_in(ran).fetch(:walls)
    end
  end

  def test_a_routine_that_never_waits_for_a_frame_is_stopped_as_c
    Dir.mktmpdir do |folder|
      unpacking = unpacking_of(folder) do |_copy, pack|
        while pack[:walls][0] >= 0
          pack[:walls][1] = 1
        end
      end

      refused = assert_raises(ArgumentError) { unpacking.run_as_c(frames: 10, stuck_after: STUCK_AFTER_SECONDS) }

      assert_match "did not wait for a frame", refused.message
    end
  end

  # A routine that goes wrong as C stops with the interpreter's error, IR::ProgramError.
  def test_a_routine_that_writes_past_a_list_stops_as_on_the_interpreter
    Dir.mktmpdir do |folder|
      unpacking = unpacking_of(folder) do |_copy, _pack|
        trail = list :trail, capacity: 2
        trail.push 1
        trail.push 2
        trail.push 3
      end

      wanted = assert_raises(VBlank::IR::ProgramError) { unpacking.run_on(Reference.new, frames: 10) }
      refused = assert_raises(VBlank::IR::ProgramError) { unpacking.run_as_c(frames: 10) }

      assert_match "is full", wanted.message
      assert_match "is full", refused.message
    end
  end
end
