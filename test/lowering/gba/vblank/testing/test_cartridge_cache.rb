# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/testing/cartridge_cache"

# A game that takes long to build keeps its cartridges in a Testing::CartridgeCache: built once for
# every test and every later run, and again only when what it is built from changes. The games here
# are one-pixel games built in the test.
class TestCartridgeCache < Minitest::Test
  private def dot_game(color)
    VBlank.game("DOT", consoles: %i[gba]) do
      screen :bitmap
      pixel setting(:floors, 1), 10, color
      halt
    end
  end

  def test_a_cartridge_is_built_once_and_read_back_by_a_later_run
    Dir.mktmpdir do |folder|
      game = dot_game(:red)
      first = VBlank::Testing::CartridgeCache.new(folder)

      refute first.cached?(game, console: :gba)
      built = first.cartridge(game, console: :gba)
      later = VBlank::Testing::CartridgeCache.new(folder)

      assert later.cached?(game, console: :gba)
      assert_equal built.buffer, later.cartridge(game, console: :gba).buffer
    end
  end

  def test_a_game_that_builds_something_else_is_built_again
    Dir.mktmpdir do |folder|
      cache = VBlank::Testing::CartridgeCache.new(folder)
      cache.cartridge(dot_game(:red), console: :gba)

      refute cache.cached?(dot_game(:blue), console: :gba)
      refute cache.cached?(dot_game(:red), console: :gba, settings: { floors: 2 })
    end
  end

  def test_a_changed_input_builds_the_game_again
    Dir.mktmpdir do |folder|
      input = File.join(folder, "copy.bin")
      File.write(input, "first")
      VBlank::Testing::CartridgeCache.new(folder, inputs: [input]).cartridge(dot_game(:red), console: :gba)
      File.write(input, "second")

      refute VBlank::Testing::CartridgeCache.new(folder, inputs: [input]).cached?(dot_game(:red), console: :gba)
    end
  end

  def test_a_fresh_run_builds_every_cartridge
    Dir.mktmpdir do |folder|
      VBlank::Testing::CartridgeCache.new(folder).cartridge(dot_game(:red), console: :gba)

      refute VBlank::Testing::CartridgeCache.new(folder, env: { "NO_BUILD_CACHE" => "1" }).cached?(dot_game(:red), console: :gba)
    end
  end

  def test_a_game_keyed_by_its_sources_is_built_again_when_one_changes
    Dir.mktmpdir do |folder|
      source = File.join(folder, "rocket.rb")
      File.write(source, "first")
      VBlank::Testing::CartridgeCache.new(folder, sources: [source]).cartridge(dot_game(:red), console: :gba)

      assert VBlank::Testing::CartridgeCache.new(folder, sources: [source]).cached?(dot_game(:blue), console: :gba)
      File.write(source, "second")
      refute VBlank::Testing::CartridgeCache.new(folder, sources: [source]).cached?(dot_game(:red), console: :gba)
    end
  end

  def test_a_cartridge_is_written_as_a_file_for_an_emulator
    Dir.mktmpdir do |folder|
      cache = VBlank::Testing::CartridgeCache.new(folder)

      path = cache.cartridge_path(dot_game(:red), console: :gba)

      assert path.end_with?(".gba")
      assert_equal cache.cartridge(dot_game(:red), console: :gba).buffer, File.binread(path)
    end
  end

  def test_a_cache_can_be_shared_with_every_ractor
    Dir.mktmpdir { |folder| assert Ractor.shareable?(VBlank::Testing::CartridgeCache.new(folder)) }
  end
end
