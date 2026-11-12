# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module IR
    module Backends
      class Native
        # A PROGRAM PLAYED AS C WITH NOBODY WATCHING (runtime/rg_headless.c's --final-state): built
        # optimised, played as fast as the computer goes to its halt or to the end of the frames
        # asked for, and read back once, as its variables and lists stood when it ended. Nothing of
        # a frame is printed or read on the way, which is what lets a long routine run at the C's
        # own speed: a port's unpacking, which may write hundreds of megabytes and wait for a frame
        # a million times (Original::Unpacking#run_as_c).
        #
        # THE COMPILED PROGRAM IS KEPT by its C (Zig.compile_without_sdl, which keys it on the
        # source, the runtime, the flags and zig's version), so the same routine asked for again,
        # in this build or a later one, is only written out as C, not compiled again.
        #
        # A STUCK PROGRAM. The C counts no steps, so a loop that never waits for a frame would play
        # forever. The program prints a "." now and then at a frame boundary, and one that prints
        # none for +stuck_after+ seconds is stopped (Stuck). Every frame can start the count again,
        # so a long run that waits now and then is never cut short.
        class FinalStateRun
          # Raised for a program stopped because it printed nothing for so long.
          class Stuck < Computer::Error; end

          # What a run left: its variables by name, and its lists by name, a list one byte wide as
          # a binary String (a byte an item, as the C keeps it) and any other as Integers.
          FinalState = Data.define(:vars, :lists)

          # How many times the file of "."s is looked at within +stuck_after+ seconds.
          DOT_CHECKS_PER_STUCK_WINDOW = 4

          # The files a run reads and writes, in a folder that lasts as long as the run: the start
          # file handed over, the final state written, the "."s printed and the complaints.
          RunFiles = Data.define(:start_file, :final_state, :dots, :complaints) do
            def self.inside(dir) = new(**members.to_h { |name| [name, File.join(dir, name.to_s)] })
          end

          def initialize(stuck_after:)
            @stuck_after = stuck_after
          end

          # +program+ played for at most +frames+ frames, handed +file+ (bytes, or nil for none) as
          # its start file, and what it left, as FinalState. IR::ProgramError where the game went
          # wrong, with the C's own sentence, as the interpreter raises it; Stuck for a program that
          # stopped waiting for frames.
          def run(program, frames:, file: nil)
            exe = Native.new.build_headless(program, mode: :fast)
            Dir.mktmpdir("vblank-final-state") do |dir|
              files = RunFiles.inside(dir)
              File.binwrite(files.start_file, file) if file
              args = [frames.to_s, "--final-state", files.final_state, *(["--start-file", files.start_file] if file)]
              status = play(exe, args, files)
              Computer::ProgramRun.refuse_unsuccessful_exit!(exe, status, File.read(files.complaints))
              read_final_state(File.binread(files.final_state))
            end
          end

          private

          # The program played to its end, its "."s and complaints written to +files+, and how it
          # ended. One that printed no "." for +@stuck_after+ seconds is stopped.
          def play(exe, args, files)
            pid = Process.spawn(exe, *args, in: File::NULL, out: files.dots, err: files.complaints)
            waiter = Process.detach(pid)
            begin
              refuse_stuck_program!(waiter, files.dots)
            ensure
              Computer::ProgramRun.kill_if_running(pid) if waiter.alive?
            end
            waiter.value
          end

          # Waits for the program to end, raising Stuck once +dots+ has not grown for +@stuck_after+ seconds.
          def refuse_stuck_program!(waiter, dots)
            dots_seen = 0
            last_dot_at = clock
            until waiter.join(@stuck_after.to_f / DOT_CHECKS_PER_STUCK_WINDOW)
              dots_now = File.size?(dots).to_i
              if dots_now > dots_seen
                dots_seen = dots_now
                last_dot_at = clock
              elsif clock - last_dot_at > @stuck_after
                raise Stuck, "the program waited for no frame in #{@stuck_after} seconds, and was stopped"
              end
            end
          end

          def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          # The file --final-state wrote: "var" lines, then each list's line and its items. Must match
          # the format runtime/rg_headless.c's header comment gives and finish_final_state writes.
          def read_final_state(bytes)
            vars = {}
            lists = {}
            at = 0
            while at < bytes.bytesize
              line_end = bytes.index("\n", at)
              line = bytes.byteslice(at, line_end - at)
              at = line_end + 1
              if line.start_with?("var ")
                name, _, value = line.delete_prefix("var ").rpartition(" ")
                vars[name.to_sym] = Integer(value)
              else
                name, _, sizes = line.delete_prefix("list ").rpartition("\t")
                width, count = sizes.split(" ").map { |number| Integer(number) }
                items = bytes.byteslice(at, width * count)
                at += width * count
                lists[name.to_sym] = list_items(items, width)
              end
            end
            FinalState.new(vars: vars, lists: lists)
          end

          def list_items(items, width)
            case width
            when 1 then items
            when 2 then items.unpack("s<*")
            else items.unpack("l<*")
            end
          end
        end
      end
    end
  end
end
