# frozen_string_literal: true

require "tmpdir"

module VBlank
  module IR
    module Backends
      module Computer
        # Runs a program a computer build made (a C program zig compiled, a script for node or for
        # Ruby), holds it to a time and a size, and reads how it ended. What it runs is the caller's
        # to say, so every build for a computer is held to the same things.
        module ProgramRun
          # What a run gave back: what the program printed and what it wrote to its error stream.
          Output = Data.define(:printed, :complaints)

          # The code a built program ends with when the GAME went wrong (rg_fault in the runtime,
          # RG_GAME_WENT_WRONG there): pushed onto a full list, played a recording nobody
          # declared. Any other way of stopping is the program's own failure.
          GAME_WENT_WRONG = 3

          # The most a program run by #run may print before the system stops it. What it
          # prints is kept in a file, and a game stuck in a loop that prints on every pass would
          # otherwise fill the disk for as long as it is given. A long run that prints every
          # frame's picture comes to a small part of this.
          MOST_PRINTED_BYTES = 2 * 1024 * 1024 * 1024

          module_function

          # Runs the program +exe+ with +args+, feeding it +input+, and gives back what it
          # printed. One still running after +seconds+ is stopped and reported: a game that loops
          # without ever waiting for the screen never ends on its own, where the interpreter
          # stops it at its step budget.
          #
          # WHAT IT READS AND PRINTS ARE FILES, read back once it has ended, and not pipes read
          # while it runs. A pipe holds a little and then makes the program wait for its reader,
          # and a reader in Ruby takes its turn again for every piece, behind every other thread
          # that is busy, since Ruby runs one thread at a time. Beside a few busy threads a
          # program that ends in a second took minutes that way, and +seconds+ ran out on a
          # program that was only waiting to be read. Through files its run is its own.
          #
          # With +complaints+ true it gives back what it printed and what it wrote to its error
          # stream, as Output.
          def run(exe, args: [], input: "", env: {}, seconds: 60, complaints: false)
            Dir.mktmpdir("vblank-run") do |dir|
              fed, printed, complained = %w[fed printed complained].map { |name| File.join(dir, name) }
              File.binwrite(fed, input)
              pid = Process.spawn(env, exe, *args.map(&:to_s), in: fed, out: printed, err: complained,
                                                               rlimit_fsize: MOST_PRINTED_BYTES)
              waiter = Process.detach(pid)
              begin
                finished = waiter.join(seconds)
              ensure
                # Stopped on every way out that leaves it running: out of time, or this thread
                # interrupted while it waited. The folder it prints into goes when this returns.
                kill_if_running(pid) if waiter.alive?
              end
              status = waiter.value
              raise Error, "#{File.basename(exe)} was still running after #{seconds} seconds, and was stopped" unless finished

              refuse_unsuccessful_exit!(exe, status, File.read(complained))
              complaints ? Output.new(printed: File.read(printed), complaints: File.read(complained)) : File.read(printed)
            end
          end

          # Raises for a program that did not end well: IR::ProgramError, with the program's own
          # sentence, for a game that went wrong — the error the interpreter raises for the same
          # game — and Error for anything else, a crash or a check the compiler put in.
          def refuse_unsuccessful_exit!(exe, status, complaint)
            return if status.success?
            raise IR::ProgramError, complaint.strip if status.exitstatus == GAME_WENT_WRONG

            raise Error, "#{File.basename(exe)} stopped (#{status}):\n#{complaint}"
          end

          # Ends a program that may already have ended. Public for Native::FinalStateRun, which
          # starts its program itself.
          def kill_if_running(pid)
            Process.kill(:KILL, pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end
end
