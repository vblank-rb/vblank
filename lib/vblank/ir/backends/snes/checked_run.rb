# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A Super Nintendo cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, or any pixel. Every checked run makes the same
        # comparison and says it in the same words (RunComparison).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Super Nintendo with nothing else changed:
        #
        #   run = VBlank::IR::Backends::SNES::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # The interpreter plays the program on the screen of the console it was built for, and the
        # two pictures are compared over the Super Nintendo's screen, the top-left 256×224 of it.
        class CheckedRun < HeadlessRun
          include CartridgeCheck

          private

          def further_difference(program, before)
            difference = self.class.sounds_difference(@interpreter_sounds, audio_played)
            difference ||= dsp_difference
            difference || (self.class.save_difference(before, @save) if SaveLayout.named_by?(program))
          end

          # The recordings sounding, each with how far through its shape the first place sounding it
          # is, as the cartridge's moments keep them (HeadlessRun#record_moment), so a shape that climbs or
          # falls a step apart from the interpreter's is found on the pass it happens.
          def sounding_levels(run) = run.active_samples.map { |name| [name, run.level_of(name)] }

          # THE SOUND UNIT ITSELF, held to the sound log: the first time the game was found waiting with
          # a register of the S-DSP holding something other than what the interpreter's log says it
          # must, as far as the entries the cartridge had logged then (each register those entries
          # write, DSPWrites.after), the pass and the registers that differ. The log agreeing is not
          # enough: a write dropped on the way, sent to the wrong register or never answered would
          # leave the log right and the sound wrong. The logs themselves are held to each other
          # first, so the cartridge's entries as far as that count are the interpreter's — read as
          # the cartridge logged them, where a stop names the tune it stopped (HeadlessRun#audio_as_logged),
          # which the interpreter's [:stop_music] does not.
          #
          # A RECORDING THE GAME PLAYS takes a voice of the four past the Advance's, chosen by where the
          # interpreter's mix puts it (Runtime::Recordings), which the log does not say: those voices'
          # registers are not held to it, nor their bits of the key-on and key-off registers, which
          # they share. Which recordings sound is held instead, at every moment (HeadlessRun#active_samples).
          def dsp_difference
            voicing = rom.built.sound_voicing
            recordings = !rom.built.recording_names.empty?
            console_bits = rom.built.console_voice_bits
            # Only as far as the interpreter's log goes: past it, nothing held the cartridge's entries.
            logged_entries = audio_as_logged.take(@interpreter_sounds.size)
            stop = DSPWrites.misnamed_stop(logged_entries, voicing)
            return "entry #{stop + 1} of the sound log: the cartridge stopped #{logged_entries[stop][1].inspect}, not the tune playing" if stop

            dsp_reads.each_with_index do |(logged, held), i|
              expected = DSPWrites.after(logged_entries.take(logged), voicing)
              expected = DSPWrites.console_voices_only(expected, console_bits) if recordings
              wrong = expected.filter_map do |register, value|
                got = held.getbyte(register)
                got &= console_bits if recordings && register == DSPWrites::KEY_OFF
                format("$%<register>02X holds $%<got>02X, the log says $%<value>02X", register: register, got: got,
                                                                                       value: value) if got != value
              end
              next if wrong.empty?

              return "the wait at the end of pass #{i + 1}: the sound unit's DSP registers: #{wrong.join(', ')}"
            end
            nil
          end

          # The interpreter's picture over the cartridge's screen, as the cartridge's Moments hold it
          # (HeadlessRun.moment_picture).
          def picture_check(screen, width, height)
            shown = RunComparison.pixels_over(screen, width, height)
            HeadlessRun.moment_picture(shown, @near, (mixed_cells(screen, width, height) if @near))
          end

          # A byte a pixel: 1 where the interpreter's screen mixed a see-through layer into it.
          def mixed_cells(screen, width, height)
            (0...(width * height)).map { |at| screen.mixed_at?(at) ? 1 : 0 }
          end
        end
      end
    end
  end
end
