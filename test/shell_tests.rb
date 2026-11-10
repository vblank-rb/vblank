# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "made_up_original"
require VBlank.root.join("examples/pacman").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_port").to_s

# WHAT A SHELL MUST NOT HOLD, for the shell tests of every runtime: none of the original's bytes, in
# any of the ways a build writes data out. A piece of the original is looked for twelve bytes at a
# time (a window with at least four different bytes, so a run of zeros is never taken for it) as
# the bytes themselves, as decimal numbers a byte or two bytes at a time, and as base64 from each of
# its first three bytes.
module OriginalBytesSearch
  WINDOW_BYTES = 12

  # Fails naming +where+ and the piece when +output+ (a String of what a build wrote) holds any of
  # +pieces+ (each a String of the original's bytes, by name).
  private def assert_holds_none_of(pieces, output, where)
    held = pieces.find { |_name, bytes| windows_of(bytes).any? { |window| written_ways(window).any? { |way| output.b.include?(way) } } }

    assert_nil held, "#{where} holds #{held&.first}, a piece of the original"
  end

  private def windows_of(bytes)
    (0..(bytes.bytesize - WINDOW_BYTES)).step(WINDOW_BYTES / 2).map { |at| bytes.byteslice(at, WINDOW_BYTES) }
                                         .select { |window| window.bytes.uniq.size >= 4 }
  end

  private def written_ways(window)
    numbers = [window.bytes, window.unpack("v*")]
    base64 = (0..2).map { |skip| [window.byteslice(skip..)].pack("m0")[0, 12] }
    [window, *numbers.flat_map { |list| [list.join(", "), list.join(",")] }, *base64].map(&:b)
  end

  # Every file under +folder+, as one String.
  private def folder_bytes(folder) = Dir.glob(File.join(folder, "**", "*")).select { |path| File.file?(path) }.map { |path| File.binread(path) }.join.b
end

# THE MADE-UP PORT A SHELL IS TESTED WITH, shared by the shell tests of each runtime
# (test/lowering/ruby/vblank/live/test_shell.rb, and the web page's and the desktop program's). The
# shell holds none of MadeUpOriginal's data; the answer key is the same game built all-in-one from
# the same copy, and the pack that build makes.
module ShellTests
  include MadeUpOriginal
  include OriginalBytesSearch

  # The made-up port: the colours copied as they are, the tiles and the heights unpacked by its
  # routine, laid out as a background with a marker placed by the heights. +version+ is the build
  # the pack names.
  private def port(from, version: "1")
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: version) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :wall_b, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        draw_rect_at heights[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 15
      end
    end
  end

  # A PORT WHOSE UNPACKING WORKS A LONG TIME BETWEEN WRITES (a port rendering music before it writes
  # a byte): +steps+ rounds of arithmetic on the copy's own bytes, which no compiler can work out
  # ahead, with no write and no wait for a frame among them, and then the heights unpacked. The
  # pack it makes does not depend on +steps+.
  private def busy_port(from, steps:)
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") do |slots|
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          busy = 0
          mixed = 0
          while busy < steps
            mixed = ((mixed * 31) + copy.byte(mixed & 255)) & 0xFFFF
            busy += 1
          end
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      heights = table :heights, pack[:heights]
      game_loop { draw_rect_at heights[0] * 4, 40, 4, 4, :white }
    end
  end

  # The made-up original on a machine where no copy of it is set: what a shell is built from, so
  # building one never writes the copy back (#original does).
  private def original_nowhere(folder)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # The port as a shell is built from it.
  private def port_without_copy(folder, version: "1") = port(original_nowhere(folder), version: version)

  # The pack the port's all-in-one build makes from the copy, taken from that build. It is built in
  # a folder of its own, so the copy it writes is never the one a test takes out of reach.
  private def all_in_one_pack(version: "1")
    Dir.mktmpdir { |folder| port(original(folder), version: version).data_pack_file }
  end

  # The pieces of the made-up original no shell may hold: the copy's packed blocks and its colours,
  # and what the port unpacks from them.
  private def original_pieces
    { "the packed tiles" => LZ77_BLOCK, "the packed heights" => RLE_BLOCK, "the colours" => PALETTE.pack("v*"),
      "the tiles" => TILE_BYTES, "the heights" => HEIGHTS.pack("C*") }
  end

  # The copy, written to a file in +folder+.
  private def copy_at(folder)
    File.join(folder, "made_up.gba").tap { |path| File.binwrite(path, COPY) }
  end

  # A file of the copy's size that is no release of the original.
  private def wrong_copy_at(folder)
    File.join(folder, "wrong.gba").tap { |path| File.binwrite(path, COPY.reverse) }
  end

  # A file no release is the size of.
  private def short_copy_at(folder)
    File.join(folder, "short.gba").tap { |path| File.binwrite(path, COPY.byteslice(0, 100)) }
  end
end

# THE PAC-MAN PORT A SHELL IS TESTED WITH (test/fixtures/pacman_port/), shared by the Pac-Man shell
# tests of each runtime. The original is pacman.gba, which the shells are handed as a copy in a
# folder of the test's own, so the copy can be taken out of reach for the second start.
module PacmanShellTests
  include OriginalBytesSearch

  # How many passes of the game are watched, and the presses: left for a while, then up, long enough
  # for Pac to eat a pellet, be caught, and blink. By pass, from 1.
  GAME_PASSES = 200
  TAPE = Ractor.make_shareable(
    (10..40).to_h { |pass| [pass, %i[left]] }.merge((41..90).to_h { |pass| [pass, %i[up]] },
                                                    (91..110).to_h { |pass| [pass, %i[right down]] })
  )

  # The port on a machine with no copy of the cartridge, what a shell is built from; +version+ names
  # the build in its pack.
  private def port_without_copy(version: "1") = PacmanPort.game(PacmanPort.original(env: {}), version: version)

  # The port with the cartridge in reach, built all-in-one.
  private def port_with_copy(version: "1")
    PacmanPort.game(PacmanPort.original(env: { "PACMAN_ROM" => PacmanFixture::ROM_PATH }), version: version)
  end

  # The pack the port's all-in-one build makes from pacman.gba, taken from that build.
  private def all_in_one_pack(version: "1") = port_with_copy(version: version).data_pack_file

  # A copy of pacman.gba in +folder+, which a test deletes to take it out of reach.
  private def copy_of_the_cartridge(folder)
    File.join(folder, "pacman.gba").tap { |path| FileUtils.cp(PacmanFixture::ROM_PATH, path) }
  end

  # The pieces of pacman.gba no shell may hold: each asset the cartridge packs, as it is packed and
  # as the port unpacks it.
  private def original_pieces
    rom = File.binread(PacmanFixture::ROM_PATH)
    pack = VBlank::Original::Pack.from_bytes(all_in_one_pack)
    PacmanPort::SLOT_ASSETS.flat_map do |slot, name|
      [["#{name}, packed", PacmanFixture.block_of(rom, name)], ["#{name}, unpacked", pack.bytes_of(slot)]]
    end.to_h
  end
end
