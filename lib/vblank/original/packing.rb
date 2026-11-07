# frozen_string_literal: true

# THE PACKED FORMATS AN UNPACKING ROUTINE CAN READ. A format is a module (Packing::Format, written
# with a Packing::BlockKit), and the copy a port's routine is handed offers the formats of the
# platform its original is for (Original::Game#platform), plus any the port names in
# `data_pack formats: [...]`. Each file is game code, so each comes in the way a part of a game does.
#
# Every platform's file is loaded here, not when a copy of that platform is first unpacked: an
# unpacking may run inside a Ractor (a test's), which cannot load a file.

VBlank.require_game_file "packing/format"   # A format's shape, and the kit its routine is written with
VBlank.require_game_file "packing/gba"      # The Game Boy Advance BIOS's LZ77 and RLE
VBlank.require_game_file "packing/genesis"  # The Sega Genesis's Nemesis tiles and Enigma plane maps

module VBlank
  module Original
    module Packing
      # The formats each platform's games keep their data in, by the platform's name. A platform
      # not here (a computer's, :pc) has none built in.
      BY_PLATFORM = Ractor.make_shareable({ gba: GBA::FORMATS, genesis: Genesis::FORMATS })

      # The formats a copy of an original for +platform+ offers, before any the port names.
      def self.formats_for(platform) = BY_PLATFORM.fetch(platform, [])

      # The platform whose formats include +name+, or nil for none.
      def self.platform_with(name) = BY_PLATFORM.find { |_, formats| formats.any? { |format| format.format_name == name } }&.first
    end
  end
end
