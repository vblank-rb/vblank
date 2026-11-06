# frozen_string_literal: true

require "digest"

module VBlank
  module Live
    # THE PLAYER'S GAME BOY ADVANCE BIOS, for the console's own start-up picture and sound before a
    # game on the desktop. The BIOS is the small program built into every console, and the start-up
    # (the logo and its chime) is something it draws and plays. It is Nintendo's work, so VBlank never
    # carries it: a game reads it from the player's own computer each time it starts, and a player
    # without one gets no start-up at all, with nothing given.
    #
    # It is looked for in three places, the first that names a file winning: the environment variable
    # VBLANK_GBA_BIOS, a line in the settings file, and gba_bios.bin in the settings folder every game
    # shares, "(all games)" (SettingsFile says where that is). A file named by the first two that is not
    # there is said, since the player asked for it; one simply not in the shared folder is not.
    #
    # A file is used only when its SHA-1 is one VBlank knows, so a damaged file, another console's BIOS
    # or a replacement BIOS is refused in plain words rather than played into a black screen. This is
    # runtime/rg_console_bios.h's rule again, held to the same table, since the desktop build and
    # `vblank run` find the same file.
    module ConsoleBIOS
      # The retail Game Boy Advance BIOS, 16384 bytes. The SHA-1 is the one both of these give:
      #   MAME, src/mame/nintendo/gba.cpp, ROM_START( gba ):
      #     ROM_LOAD( "gba.bin", 0x000000, 0x004000, CRC(81977335) SHA1(300c20df...) )
      #   libretro-database, dat/System.dat, "Nintendo - Game Boy Advance":
      #     rom ( name gba_bios.bin size 16384 crc 81977335 md5 a860e8c0... sha1 300c20df... )
      # (libretro's mGBA page gives the same MD5, a860e8c0b6d573d191e4ec7db1b1e4f6.)
      KNOWN_SHA1 = ["300c20df6731a33952ded8c436f7f186d25d3492"].freeze
      SIZE_IN_BYTES = 16_384
      FILE_NAME = "gba_bios.bin"
      ENVIRONMENT_VARIABLE = "VBLANK_GBA_BIOS"

      # A BIOS VBlank can play the start-up from.
      Found = Data.define(:path)
      # A file named as the BIOS that cannot be used, and the words that say so.
      Refused = Data.define(:path, :message)

      NO_START_UP_SENTENCE = " The game starts without the start-up picture of the console."

      # Gives Found, Refused, or nil when there is no BIOS to look at. +environment+ is
      # VBLANK_GBA_BIOS's value, +setting+ the settings file's, +shared_folder+ the folder every
      # game's settings share, each nil when there is none. +known_sha1+ is the checksums accepted.
      def self.find(environment:, setting:, shared_folder:, known_sha1: KNOWN_SHA1)
        if environment && !environment.empty?
          found_or_refused(environment, "The environment variable #{ENVIRONMENT_VARIABLE}", known_sha1)
        elsif setting && !setting.empty?
          found_or_refused(setting, "The settings file", known_sha1)
        elsif shared_folder
          path = File.join(shared_folder, FILE_NAME)
          found_or_refused(path, nil, known_sha1) if File.exist?(path)
        end
      end

      # +named_by+ is what named the path, for the words when there is no file at it.
      def self.found_or_refused(path, named_by, known_sha1)
        unless File.exist?(path)
          return Refused.new(path:, message: "VBlank cannot find #{path}. #{named_by} gives this path for the " \
                                             "Game Boy Advance BIOS. Make sure that the path is correct.#{NO_START_UP_SENTENCE}")
        end

        bytes = File.binread(path, SIZE_IN_BYTES + 1)
        if bytes.nil? || bytes.bytesize != SIZE_IN_BYTES
          return Refused.new(path:, message: "VBlank cannot use #{path} as the Game Boy Advance BIOS. The file is " \
                                             "not #{SIZE_IN_BYTES} bytes long. A Game Boy Advance BIOS is #{SIZE_IN_BYTES} bytes " \
                                             "long.#{NO_START_UP_SENTENCE}")
        end

        sha1 = Digest::SHA1.hexdigest(bytes)
        return Found.new(path:) if known_sha1.include?(sha1)

        Refused.new(path:, message: "VBlank cannot use #{path} as the Game Boy Advance BIOS. The SHA-1 checksum " \
                                    "of the file is #{sha1}. VBlank uses only a BIOS with the SHA-1 checksum " \
                                    "#{known_sha1.join(' or ')}.#{NO_START_UP_SENTENCE}")
      rescue SystemCallError
        Refused.new(path:, message: "VBlank cannot read #{path}.#{NO_START_UP_SENTENCE}")
      end
      private_class_method :found_or_refused
    end
  end
end
