# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A cartridge that is only its file: the bytes of a .gba or a .gbc, and nothing the build
    # worked out about them. A cartridge somebody else made is one, and so is one this framework
    # built once it has been written to a file — what the build knew is in the program that
    # built it and never in the file.
    #
    # It can be run, and its screen and its memory read. What it cannot do is name what
    # anything in it is called: no variable has a name and no sprite does, because the
    # names were the build's. A reader that is asked for one says so (see Verifier).
    #
    # It answers what a running console asks of a cartridge — which console it is for, its
    # title, its bytes, and to be written to a file for the emulator to open — with nothing
    # where a build record would be. What a cartridge can only report of itself with a record
    # (its size by routine, its profile) it does not answer at all.
    class CartridgeFile
      # The kinds of cartridge a file can be, one a console, each knowing its own header.
      def self.kinds = Console.kits.map(&:cartridge)

      attr_reader :path, :buffer

      # +multitap+ plays the cartridge with the console's adapter for more controllers in its
      # second port (Console::Kit#multitap_name): a Super Multitap on the Super Nintendo, a Team
      # Player on the Genesis, a Multitap on the PlayStation. The third and fourth players' buttons
      # then reach its plugs. A file has no program to ask whether the game reads one, so the
      # caller says so. Without it the second port has a plain controller, and a console with no
      # such adapter refuses it.
      def initialize(path, multitap: false)
        raise ArgumentError, "There is no cartridge file at #{path}. Give the path of a cartridge file." unless File.file?(path)

        @path = path.to_s
        @buffer = File.binread(path).freeze
        @kind = self.class.kinds.find { |kind| kind.header?(@buffer) }
        refuse_non_cartridge!
        Console.for(console).refuse_missing_multitap! if multitap
        @multitap = multitap == true
      end

      # Whether it plays with the adapter for more controllers in (+multitap+ above).
      def multitap? = @multitap

      # Nothing built this, so there is no record of how.
      def built = nil
      def source_program = nil
      def var_addresses = nil

      # The console the cartridge is for, and the title field of its header, read where that
      # console's cartridges keep it.
      def console = @kind.console
      def header_title = @kind.title_field_of(@buffer)

      # Write the cartridge's bytes to +path+.
      def write(path) = File.binwrite(path, @buffer)

      private

      # A file whose header is no cartridge's is something else, given where a cartridge goes.
      def refuse_non_cartridge!
        return if @kind

        raise ArgumentError, "The file at #{@path} is not a cartridge. Every cartridge has the same bytes at one place " \
                             "in its heading, and this file does not. Give the path of a cartridge file."
      end
    end
  end
end
