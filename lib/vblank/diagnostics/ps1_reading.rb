# frozen_string_literal: true

module VBlank
  module Diagnostics
    # WHAT A READER OVER A RUNNING PLAYSTATION PROGRAM CAN BE ASKED that only the PlayStation's way of
    # keeping things answers — the same questions an Advance reader answers its own way (AdvanceReading).
    #
    # A PlayStation program plays in Beetle PSX (ruby-ps1-emulator), not in libmgba, and the one reader
    # (Verifier) plays it there through PS1Probe: its picture, its memory by address, and buttons held,
    # which is what a film asks, and the passes the game finished, from the runtime's own count
    # (CountedPasses), as a profile reads them, and where each sprite is, from the rows the runtime keeps.
    module PS1Reading
      include CountedPasses

      # Lists of 256 colours, kept in video RAM (nothing is drawn with one yet).
      PALETTE = Verifier::PaletteLayout.new(half: 0, group: 256)

      # A PlayStation keeps a game's saves on a memory card of 128K (nothing is made to save yet, which
      # Lowering::NOT_LOWERED_YET says).
      SAVE_FILE = Verifier::SaveFileLayout.new(whole: 0x20000, clock_bytes: 0)

      # WHERE THE SPRITES ARE, by name (Reference#sprites): the rows the runtime keeps of the sprites the
      # last pass placed (IR::Backends::PS1::Runtime::Tiles::DRAWN), read off the program's RAM. A painted
      # screen's sprites are drawn into its picture, and none is kept.
      def sprites(name = nil)
        refuse_missing_build_record!("which of its sprites is which")
        ensure_rendered!
        @drawn ||= IR::Backends::SpriteNames.new(@rom.source_program)
        rows = @rom.built.drawn_sprite_rows(@drawn) { |address| mem32(address) }
        name ? @drawn.rows_named(rows, name) : rows
      end

      # WHEN THE PROGRAM BEGAN. A PlayStation program is copied into RAM before its first instruction
      # runs, by the BIOS from a disc on a console (seconds of it) and by Beetle's loader here, longer
      # for a longer program; so the screen's blanks a program can count are those since it began, and a
      # test of what it counts holds it to those. Asked for before anything is read, since the emulator
      # watches for it from power-on (RubyPS1Emulator::Core#watch_program_start!).
      def watch_program_start!
        raise ArgumentError, "Ask to watch for the program's start before reading anything from the run." if @rendered

        @watching_program_start = true
        self
      end

      # How many of the screen's blanks came before the program's first instruction
      # (RubyPS1Emulator::Core#blanks_before_program).
      def blanks_before_program
        raise ArgumentError, "Ask to watch for the program's start (watch_program_start!) before the run." unless @watching_program_start

        ensure_rendered!
        @probe.blanks_before_program
      end

      # No song is ever playing: the PlayStation's build refuses a game that plays one, which
      # Lowering::NOT_LOWERED_YET says (Reference#music_playing).
      def music_playing = nil

      # NO SAMPLES YET. Beetle PSX mixes the sound chip's output and hands it over, and the emulator
      # gem counts those samples without keeping them (RubyPS1Emulator::Core#sound_frames). So a
      # reader has none to give, and says so; silence would read as a program that makes no sound.
      def last_frame_sound = refuse_ps1_samples!
      def last_frame_samples = refuse_ps1_samples!
      def loudest_by_frame = refuse_ps1_samples!
      def loudest_on_speaker_by_frame(_speaker) = refuse_ps1_samples!

      private

      # Before any frame runs: the runtime counts its own passes (CountedPasses), and the emulator
      # watches for the program's start where a test asked it to.
      def watch_passes!
        @probe.watch_program_start! if @watching_program_start
      end

      def refuse_ps1_samples!
        raise ArgumentError, "The emulator for a PlayStation program gives no sound samples yet, so this reader " \
                             "cannot say what the program put out. It counts the samples and does not keep them. " \
                             "Compare the sound of a cartridge for another console instead."
      end
    end
  end
end
