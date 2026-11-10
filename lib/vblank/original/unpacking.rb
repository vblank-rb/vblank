# frozen_string_literal: true

module VBlank
  module Original
    # A DATA PACK'S UNPACKING, AS A PROGRAM OF ITS OWN: the game's unpacking routine
    # (`slots.fill_from_copy`) built into a program that reads the copy and writes every slot of the
    # pack, and what to read back from a run of it.
    #
    # WHY A PROGRAM OF ITS OWN, and not a part of the game. The routine has to run before anything
    # reads a slot, and a build reads slots as the game is built: `image` and `table` take a slot's
    # bytes then, in Ruby. So built all-in-one (every build today, and every cartridge for good)
    # the routine runs as the game is built, built as Ruby (#run_as_ruby, from
    # Builder::DataPacks#play_unpacking), and the pack is made from what it wrote. A cartridge never
    # carries the routine.
    #
    # The routine is ordinary game code, made of the verbs and IR every backend already plays (a
    # table, a byte list, loops, routines, `wait_vblank`, `halt`), so every run plays it as it plays
    # any game, checked against the interpreter, and nothing new is asked of a backend.
    #
    # THE COPY IS A FILE THE PROGRAM IS HANDED AS IT STARTS (IR::StartFile), however it is built,
    # so the program holds none of the original's bytes: a copy of tens of megabytes held as a
    # table, one Ruby number a byte, and written out again as text for the pack cache's key, would
    # cost many times its size. Built all-in-one, the build hands it the copy it read (#run_on). A
    # build that leaves the pack out (`pack_at_start:`, Builder::DataPacks) has no copy, so its
    # program is built for a copy of a known size (`pack.unpacking(release:)`, which holds the
    # release's size), and a shell hands it the player's. Played to its `halt` on any computer's
    # runtime handed that file, BYTES read back after it is the pack.
    # The routine itself does not change for any of that. What a shell must still add is playing it
    # inside the shipped game before the game, and keeping the pack it wrote.
    #
    # WHAT IS IN IT. The copy is a table of bytes (COPY), read from the file. The pack is one list of
    # bytes (BYTES), every slot in it one after another in the pack's order (#places), as the pack
    # file keeps them.
    # The slots copied as they are (`at:`) are copied first, then the routine runs, then FINISHED is
    # set and the program halts. The building blocks (CopyReader, Packing::BlockKit) add what they
    # write to BYTES_DONE as they go and wait for the next frame every so often, so a shell can show
    # how far the unpacking has got. The first thing that goes wrong (Fault) is kept in the FAULT_
    # variables and nothing after it overwrites it. +format_words+ are what a person calls each
    # format the copy offered, in the order a fault numbers them.
    #
    # +copy_bytes+ is the copy where the build read one (an all-in-one build), handed to the program
    # as its file whenever it is played (#run_on); nil for a shell's, which is handed the player's.
    Unpacking = Data.define(:program, :slots, :copy_size, :format_words, :copy_bytes)

    class Unpacking
      def initialize(program:, slots:, copy_size:, format_words:, copy_bytes: nil) = super

      # A run of the program on +player+ (the interpreter, or any computer runtime's player), handed
      # the copy the build read where it read one. +options+ are the player's `run`'s.
      def run_on(player, **options)
        player = player.hand_file(copy_bytes) if copy_bytes
        player.run(program, **options)
      end

      # How long the routine may run without waiting for a frame before the build stops it.
      SECONDS_WITHOUT_FRAME = 30

      # A run of the program built as Ruby and played in this process (IR::Backends::Ruby), handed
      # the copy, for at most +frames+ frames: the way a shell plays it on a player's machine, and
      # many times faster than the interpreter (Builder::DataPacks#play_unpacking). Its variables and lists
      # are read back as an interpreter run's are. IR::Backends::Ruby::RuntimeGap where the Ruby
      # runtime cannot play the program yet; IR::ProgramError where it stops as the interpreter would.
      #
      # A STUCK ROUTINE. The game built as Ruby runs straight through until it waits for a frame,
      # as a cartridge does: it counts no steps, which is much of why it is fast. So a loop that
      # never waits would keep the build forever, where the interpreter's step budget stopped it.
      # A watchdog thread stops it instead (ArgumentError) once +stuck_after+ seconds go by with no
      # frame. Every frame starts the count again, so a long unpacking that waits now and then is
      # never cut short. This is the build's alone: a game played as Ruby has no watchdog.
      #
      # The watchdog's StuckRoutine is taken only while the game plays. One sent just as the play
      # ended waits until the watchdog is stopped, and is then dropped, since the routine was not
      # stuck after all.
      def run_as_ruby(frames:, stuck_after: SECONDS_WITHOUT_FRAME)
        game = IR::Backends::Ruby.new.live_game(program)
        game.hand_file(copy_bytes) if copy_bytes
        player = FrameLimitedPlayer.new(frames)
        watchdog = start_watchdog(player, Thread.current, stuck_after)
        played = false
        begin
          Thread.handle_interrupt(StuckRoutine => :never) do
            Thread.handle_interrupt(StuckRoutine => :immediate) { game.play(player) }
            played = true
            player.stop_watching
          end
        rescue StuckRoutine
          raise unless played
        ensure
          watchdog.kill
          watchdog.join
        end
        RubyRun.new(game.state)
      end

      # What the watchdog stops a routine with that has gone too long without a frame.
      class StuckRoutine < ArgumentError; end

      # Whoever plays the Ruby run: holds no buttons (no player is connected), and stops it after
      # +frames+ frames, as the interpreter's `frames:` does, so a routine that never ends cannot
      # keep the build forever. It also keeps when the last frame ended, for the watchdog, which it
      # lets raise only while the run is still playing.
      class FrameLimitedPlayer
        NO_BUTTONS = [].freeze

        def initialize(frames)
          @left = frames
          @lock = Mutex.new
          @watched = true
          @last_frame_at = now
        end

        # Nobody is at the controls of an unpacking, so no state is ever asked for.
        def take_state_request = nil

        def buttons_after(_pixels, _left, _right)
          @lock.synchronize { @last_frame_at = now }
          @left -= 1
          @left.positive? ? NO_BUTTONS : nil
        end

        # Raises +error+ in +thread+ if the run is still playing and has had no frame for +seconds+;
        # true when it did.
        def raise_if_stuck(thread, seconds, error)
          @lock.synchronize do
            return false unless @watched && now - @last_frame_at > seconds

            @watched = false
            thread.raise(error)
            true
          end
        end

        def stop_watching = @lock.synchronize { @watched = false }

        private

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # A Ruby run's variables and lists, by the names a run of the interpreter is asked by.
      RubyRun = Data.define(:state) do
        def list(name) = state.lists.fetch(name.to_s)
        def [](name) = state.vars.fetch(name.to_s)
      end

      COPY = Messages::MadeNames.make(:unpacking_part, part: :copy)
      BYTES = Messages::MadeNames.make(:unpacking_part, part: :bytes)
      BYTES_DONE = Messages::MadeNames.make(:unpacking_part, part: :bytes_done)
      FINISHED = Messages::MadeNames.make(:unpacking_part, part: :finished)
      PROGRESS = Messages::MadeNames.make(:unpacking_part, part: :progress)
      FAULT_KIND = Messages::MadeNames.make(:unpacking_part, part: :fault_kind)
      FAULT_AT = Messages::MadeNames.make(:unpacking_part, part: :fault_at)
      FAULT_DETAIL = Messages::MadeNames.make(:unpacking_part, part: :fault_detail)

      # WHAT WENT WRONG AS THE ROUTINE RAN, the first time anything did. +kind+ is one of the three
      # below; +at+ is a place in the copy for the first two and a byte outside the slot for the
      # third (a format's write names the first byte past the slot's end, whether it found the
      # write did not fit when the size was expected or when the byte was written); +detail+ is the
      # number of the format the routine was told (Unpacking#format_words), or the slot's number in
      # the pack's order.
      Fault = Data.define(:kind, :at, :detail)

      class Fault
        WRONG_FORMAT = 1
        READ_PAST_END = 2
        WRITE_OUTSIDE_SLOT = 3

        # The error the build stops with, in words, for a pack of +slots+ from a copy of +copy_size+
        # bytes whose formats are called +format_words+.
        def error(slots, copy_size, format_words)
          case kind
          when WRONG_FORMAT
            name = format_words.fetch(detail)
            WrongCopy.new("The unpacking routine reads a block packed with #{name} at #{at} (0x#{at.to_s(16)}) in the " \
                          "copy. The block there is not packed with #{name}. Correct at: for this release, or use " \
                          "the unpacking that matches the block.")
          when READ_PAST_END
            WrongCopy.new("The unpacking routine reads byte #{at} (0x#{at.to_s(16)}) of the copy, and the copy has " \
                          "bytes 0 to #{copy_size - 1}. Correct the place it reads for this release.")
          else
            slot = slots.fetch(detail)
            ArgumentError.new("The unpacking routine writes byte #{at} of slot :#{slot.name}, and the slot holds bytes " \
                              "0 to #{slot.byte_size - 1}. A write cannot go past its slot. Correct start:, count: or " \
                              "the place written, or make the slot bigger.")
          end
        end
      end

      # Where each of +slots+ starts in the list of the pack's bytes, by name.
      def self.places_of(slots)
        start = 0
        slots.to_h { |slot| [slot.name, start].tap { start += slot.byte_size } }
      end

      # Where each slot starts in the list of the pack's bytes, by name.
      def places = Unpacking.places_of(slots)

      # How many bytes the whole pack holds.
      def byte_size = slots.sum(&:byte_size)

      # Each slot's bytes, by name, in what +run+ (a run of #program, on any backend) wrote.
      def slot_bytes_in(run)
        bytes = run.list(BYTES).map { |item| item & 0xFF }
        places.to_h { |name, start| [name, bytes[start, slot_named(name).byte_size].pack("C*")] }
      end

      # How many bytes +run+ has unpacked so far, of #byte_size.
      def bytes_done_in(run) = run[BYTES_DONE]

      # Whether +run+ got to the end of the routine.
      def finished_in?(run) = run[FINISHED] == 1

      # The first Fault +run+ found, or nil when nothing went wrong.
      def fault_in(run)
        kind = run[FAULT_KIND]
        kind.zero? ? nil : Fault.new(kind: kind, at: run[FAULT_AT], detail: run[FAULT_DETAIL])
      end

      private

      def slot_named(name) = slots.find { |slot| slot.name == name }

      def start_watchdog(player, play_thread, stuck_after)
        error = StuckRoutine.new(
          "The data pack's unpacking routine ran for #{stuck_after} seconds and did not wait for a frame. " \
          "Look for a loop in `slots.fill_from_copy` that never stops. If a long loop is correct, " \
          "call `wait_vblank` in it now and then."
        )
        Thread.new do
          sleep(stuck_after / 4.0) until player.raise_if_stuck(play_thread, stuck_after, error)
        end
      end
    end
  end
end
