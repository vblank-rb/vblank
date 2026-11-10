# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      module Computer
        # What tells a game played as a computer's program from the same game played on the interpreter: the
        # comparison every checked run makes (RunComparison), and besides it, a program played
        # both ways a frame at a time keeping every pixel of every frame (#lowered_snapshots,
        # #reference_snapshots), which is dear, and is what a check that found two pictures differ
        # uses to say where.
        module Differences
          include RunComparison

          # One moment of a run: its heading ("frame 3", "end"), the variables, the picture shown,
          # the sound log up to then, and the sprites last drawn, each saying whose it is.
          Snapshot = Data.define(:heading, :variables, :picture, :sounds, :sprites) do
            # This snapshot read as the game +program+ declared it, by its names
            # (RunComparison::RecordedFrame).
            def read_with(program) = RunComparison::RecordedFrame.new(variables: variables, program: program)
          end

          # The snapshots the windowless program printed. +held+ is down from power-on, before
          # the game's first statement, and +buttons+ give what is held on each frame from the
          # first on. +start_file+ is the bytes of the file the program is handed as it starts
          # (IR::StartFile), or nil for none.
          def lowered_snapshots(program, frames:, buttons:, mode:, held: [], start_file: nil)
            pass_buttons = IR::Buttons::PassButtons.new
            from_power_on = held.empty? ? [] : ["--held-from-power-on", pass_buttons.headless_input_line(held)]
            input = (1..frames).map { |frame| "#{pass_buttons.headless_input_line(buttons.fetch(frame, []))}\n" }.join
            Dir.mktmpdir("vblank-snapshots") do |dir|
              handed = []
              if start_file
                handed = ["--start-file", File.join(dir, "start_file")]
                File.binwrite(handed.last, start_file)
              end
              parse_snapshots(run_headless_program(program, mode, args: [frames, "--every-picture", *from_power_on, *handed],
                                                                  input: input), program)
            end
          end

          # +program+ built to run with no window and run with +args+ and +input+, giving back what it
          # printed: each build runs the game it writes, the way +mode+ names where it has more than
          # one way to build it.
          def run_headless_program(_program, _mode, args:, input:)
            raise NotImplementedError, "#{self.class} must run the program it builds with #{args.inspect} and #{input.inspect}"
          end

          def reference_snapshots(program, frames:, buttons:, held: [], start_file: nil)
            interpreter = Reference.new.hold(*held).hand_file(start_file)
            snapshots = []
            interpreter.input_each_frame { |frame| buttons.fetch(frame, []) }
                       .each_vblank { |frame| snapshots << reference_moment(interpreter, "frame #{frame}") }
                       .run(program, frames: frames)
            snapshots << reference_moment(interpreter, "end")
          end

          private

          def reference_moment(interpreter, heading)
            Snapshot.new(heading: heading, variables: interpreter.vars.dup, picture: interpreter.screen.shown,
                         sounds: interpreter.audio.dup, sprites: interpreter.sprites)
          end

          # Where two pictures of a screen +width+ pixels wide differ.
          def picture_difference(want, got, width)
            return nil if want == got
            return "#{lowered_side} shows #{got.size} pixels, Reference #{want.size}" unless want.size == got.size

            first = want.each_index.find { |i| want[i] != got[i] }
            differing = want.each_index.count { |i| want[i] != got[i] }
            "the pictures differ in #{differing} pixels, the first at (#{first % width}, #{first / width}): " \
              "#{lowered_side} shows #{format('%04x', got[first])}, Reference #{format('%04x', want[first])}"
          end

          # The program's printed moments. A sound line belongs to the log as it grows, so each
          # moment holds the log up to its own heading — which is where the interpreter's
          # each_vblank reads it.
          def parse_snapshots(text, program)
            sound_log = SoundLog.new(program)
            drawn = DrawnSprites.new(program)
            sounds = []
            moments = []
            text.each_line(chomp: true) do |line|
              # The Ruby runtime prints once, before any frame, which compiler runs it ("jit yjit").
              next if line.start_with?("jit ")

              if line.start_with?("sound ")
                sounds << sound_log.entry_from(line)
              elsif line.start_with?("frame ") || line == "end"
                moments << [line, [], sounds.size]
              else
                moments.last[1] << line
              end
            end
            moments.map do |heading, rows, sound_count|
              Snapshot.new(heading: heading, variables: HeadlessRun.variables_in(rows),
                           picture: HeadlessRun.picture_in(rows), sounds: sounds.take(sound_count),
                           sprites: drawn.rows_in(rows))
            end
          end
        end
      end
    end
  end
end
