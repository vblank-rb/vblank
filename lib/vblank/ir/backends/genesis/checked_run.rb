# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # A Genesis cartridge played in the emulator (HeadlessRun), and then the same buttons, pass for
        # pass, played on the interpreter — stopping at the first pass the two disagree on, about any
        # variable, any list or pool, or any pixel (CartridgeCheck says how).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Genesis with nothing else changed. The interpreter
        # plays the program on the screen of the console it was built for, and the two pictures are
        # compared over the Genesis's, 320×224, each colour as the three bits of each channel the
        # console keeps (Console::Description#color_bits).
        class CheckedRun < HeadlessRun
          include CartridgeCheck

          private

          # THE SOUND LOG AND THE CHIPS THEMSELVES, past the moments: every entry of the log, and the first time
          # the game was found waiting with a chip's register holding something other than what the
          # interpreter's log says it must, as far as the entries the cartridge had logged then
          # (ChipWrites.after). The log agreeing is not enough: a write dropped on the way or sent to the
          # wrong register would leave the log right and the sound wrong.
          def further_difference(program, before)
            difference = self.class.sounds_difference(@interpreter_sounds, audio_played)
            difference ||= chip_difference
            difference || (self.class.save_difference(before, @save) if SaveLayout.named_by?(program))
          end

          # The recording sounding, as the cartridge's moments keep it.
          def sounding_levels(run) = run.active_samples

          def chip_difference
            voicing = rom.built.sound_voicing
            # Only as far as the interpreter's log goes: past it, nothing held the cartridge's entries.
            logged_entries = audio_as_logged.take(@interpreter_sounds.size)
            stop = ChipWrites.misnamed_stop(logged_entries, voicing)
            return "entry #{stop + 1} of the sound log: the cartridge stopped #{logged_entries[stop][1].inspect}, not the tune playing" if stop

            chip_reads.each_with_index do |(logged, (psg, fm)), i|
              wrong = ChipWrites.after(logged_entries.take(logged), voicing).filter_map do |(chip, register), value|
                got = chip == :psg ? psg.fetch(register) : fm.getbyte(register)
                format("%<chip>s register $%<register>02X holds $%<got>02X, the log says $%<value>02X", chip: chip, register: register, got: got, value: value) if got != value
              end
              return "the wait at the end of pass #{i + 1}: the sound chips: #{wrong.join(', ')}" unless wrong.empty?
            end
            nil
          end
        end
      end
    end
  end
end
