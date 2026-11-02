# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # A Game Boy Color cartridge played in the emulator (HeadlessRun), and then the same buttons,
        # pass for pass, played on the interpreter — stopping at the first pass the two disagree on,
        # about any variable, any list or pool, any pixel, or how far the sound log has grown — and
        # at the end, about every entry of the sound log (GBC::SoundLog reads the cartridge's) and the
        # save memory. Every checked run makes the same comparison and says it in the same words
        # (RunComparison).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one
        # of these instead and play its game on a Game Boy Color with nothing else changed:
        #
        #   run = VBlank::IR::Backends::GBC::CheckedRun.new
        #   run.input_each_frame { |frame| frame < 30 ? [:right] : [] }.run(game.program, frames: 60)
        #   run[:x]
        #
        # The interpreter plays the program on the screen of the console it was built for. A program
        # built for the Advance plays on the Advance's larger screen there, so the two pictures are
        # compared over the Color's screen, the top-left 160×144 of it: what is past that the
        # cartridge cannot show. (Whether a test of a program built for the Advance is played here at
        # all is VBlank::Testing's decision.)
        class CheckedRun < CartridgeCheckedRun
          def initialize(save: SaveImage.new)
            super(HeadlessRun, save: save)
          end

          # The same clock on both sides, started at the same moment: the Color's chip, which keeps
          # no date, whichever console the program was built for.
          def clock_at(time, set: true)
            @cartridge.clock_at(time, set: set)
            @clock_started = time
            @clock_set = set
            self
          end

          private

          # A log that grew differently says which entry it first differs at, read to the end.
          def moments_difference(moments)
            difference = super
            return difference unless difference&.include?("sound log")

            [difference, self.class.sounds_difference(@interpreter_sounds, @cartridge.whole_audio)].compact.join(", and ")
          end

          def further_difference(program, before)
            difference = self.class.sounds_difference(@interpreter_sounds, @cartridge.audio_played)
            difference || (self.class.save_difference(before, @save) if SaveLayout.named_by?(program))
          end

          def prepare_interpreter(interpreter)
            interpreter.clock_at(@clock_started, set: @clock_set, keeps_date: false) if @clock_started
            interpreter.frames_setting_up(@cartridge.dark_frames_counted)
          end

          def sounding_levels(run) = run.active_samples.dup
          def motor_of(run) = run.motor_on?
        end
      end
    end
  end
end
