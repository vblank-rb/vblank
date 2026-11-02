# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # A GAME'S RULES AS FAST AS THE MACHINE CAN PLAY THEM, for a bot that plays one long run many
        # times: the program with nothing to see or hear (IR::RulesOnly), built as C, read only as
        # far as somebody asks.
        #
        # THE DRAWING WAS NOT MOST OF IT. A run read frame by frame has the program print every
        # variable and list every frame, and this side read them all back, which for a game with
        # long lists costs more than drawing does. So here the program prints nothing, and a number
        # read is a question sent to it and an answer (`--asked`, runtime/rg_headless.c). A script
        # that reads three numbers a frame pays for three numbers.
        #
        # ITS FRAMES ARE NOT THE CONSOLE'S. A pass is a frame here, because nothing is late, so a tape
        # made here does not play on a cartridge. This finds tactics and seeds, and the tape that
        # counts is recorded on the cartridge.
        class RulesRun < HeadlessRun
          def run(program, max_steps: nil, frames: nil)
            super(RulesOnly.of(program), max_steps: max_steps, frames: frames)
          end

          # There is no picture, by design.
          def screen = refuse_unanswered!(:screen)

          def [](name) = @stdin ? variable_asked(name) : super

          private

          def list_items(name) = @stdin ? list_asked(name) : super

          def play(exe, frames)
            Dir.mktmpdir("vblank-rules") do |dir|
              Open3.popen2(exe, frames.to_s, "--asked", *save_options(dir), *held_options, *clock_options) do |stdin, stdout, waiter|
                @stdout = stdout
                frame = 0
                while stdout.gets == "buttons?\n"
                  frame += 1
                  answer_with_buttons(stdin, frame)
                end
                @stdin = nil
                rows = stdout.each_line.map(&:chomp)
                refuse_failed_run!(exe, waiter.value, "")
                read_state_from(rows)
              end
            end
          end

          # Open for questions only while the program waits for this frame's buttons.
          def answer_with_buttons(stdin, frame)
            @stdin = stdin
            buttons = @input_script ? @input_script.call(frame) : @held
            @on_vblank&.call(frame)
            @stdin = nil
            stdin.puts(self.class.button_mask(buttons))
            stdin.flush
          end

          def variable_asked(name) = self.class.variables_in(rows_asked(name)).fetch(name, 0)

          def list_asked(name)
            self.class.lists_in(rows_asked(name)).fetch(name) { @declared_lists.include?(name) ? [] : nil }
          end

          def rows_asked(name)
            @stdin.puts("? #{name}")
            @stdin.flush
            rows = []
            rows << @stdout.gets.chomp until rows.last == "."
            rows
          end
        end
      end
    end
  end
end
