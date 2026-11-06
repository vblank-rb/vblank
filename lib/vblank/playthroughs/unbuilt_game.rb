# frozen_string_literal: true

require "zlib"

module VBlank
  module Playthroughs
    # A GAME CHECKED AND NOT BUILT INTO A CARTRIDGE, standing where a cartridge stands for a
    # playthrough that runs the game itself: as Ruby, as JavaScript, as C, its rules alone, or in
    # the interpreter (LoweredGame). `vblank run` plays a script or a tape on one of these, so it
    # never waits for a cartridge it would not play. A big game's cartridge is built twice, once to
    # measure it, and that is most of a minute.
    #
    # It answers what a playing asks of what it plays: the program, the console, a title and a
    # checksum for the tape's heading. It has no bytes, so the emulator cannot play it, a save has
    # nowhere to go, and a tape made on it shows it only by its checksum, which is of the game's
    # source and settings and not of a cartridge's bytes.
    class UnbuiltGame
      attr_reader :source_program, :checksum

      # +program+ is the checked program (Cartridge::Game#checked_program). +title+ is the game's
      # title, and +source+ what it was built from (the game file's text, its settings), for the
      # checksum a tape writes in its heading for a person.
      def initialize(program, title:, source:)
        @source_program = program
        @title = title.to_s
        @checksum = Zlib.crc32(source.to_s)
      end

      def console = @source_program.console
      def header_title = @title

      # No cartridge was built, so there is no record of how, and no bytes.
      def built = nil
    end
  end
end
