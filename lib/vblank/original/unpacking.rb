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
    # the routine runs as the game is built, the fastest way this machine has (#run_fastest, from
    # Builder::DataPacks#play_unpacking: as C, as Ruby, or on the interpreter), and the pack is
    # made from what it wrote. A cartridge never carries the routine.
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
    #
    # THE FRAMES A GAME NAMES ARE WRITTEN LAST (+frames+, a FrameRecord::Section). Once every slot
    # is filled, the routine reads each frame of a sprite the game names from its slot and writes
    # it after the last slot as a record of VBlank's own (FrameRewrite), which is all that anything
    # drawing a pose reads. That is so for a slot copied as it is too, in a pack with no routine.
    # BYTES is the slots and then those records, as the pack's file is after its header.
    Unpacking = Data.define(:program, :slots, :copy_size, :format_words, :copy_bytes, :frames)

    class Unpacking
      def initialize(program:, slots:, copy_size:, format_words:, copy_bytes: nil, frames: FrameRecord::Section.new(sources: [])) = super

      # A run of the program on +player+ (the interpreter, or any computer runtime's player), handed
      # the copy the build read where it read one. +options+ are the player's `run`'s.
      def run_on(player, **options)
        player = player.hand_file(copy_bytes) if copy_bytes
        player.run(program, **options)
      end

      # How long the routine may run without waiting for a frame before the build stops it.
      SECONDS_WITHOUT_FRAME = 30

      # How far a routine may go before it is taken to be stuck. A routine reads each byte of the
      # copy and writes each byte of the pack a few times at most, and waits for the next frame at
      # most once a byte; so the frames it can need, and the steps one frame can take on the
      # interpreter, follow from the two sizes. A routine past either is in a loop that does not end.
      STEPS_A_BYTE = 64
      SPARE_FRAMES = 100
      SPARE_STEPS = 100_000

      def most_frames = copy_size + byte_size + SPARE_FRAMES
      def most_steps_a_frame = ((copy_size + byte_size) * STEPS_A_BYTE) + SPARE_STEPS

      # THE FASTEST RUN THIS MACHINE HAS, for at most +frames+ frames: built as C where zig is
      # installed (#run_as_c), else built as Ruby (#run_as_ruby), and on the interpreter where the
      # Ruby runtime cannot play the program yet. What a build plays (Builder::DataPacks#play_unpacking),
      # and what a game's test asks for to make the pack a build makes. Every way writes the same
      # pack, byte for byte: the interpreter is the answer key, and the tests hold the C and Ruby
      # runs to it. A program the C build refuses is played as Ruby; so is one whose C build or run
      # fails another way (a compile that fails, a program that crashes or runs out of memory),
      # which is a fault in VBlank and is warned of in one line. IR::ProgramError where the routine
      # stops as the interpreter would.
      def run_fastest(frames: most_frames, stuck_after: SECONDS_WITHOUT_FRAME)
        play_fastest(frames: frames, stuck_after: stuck_after) { run_as_c(frames: frames, stuck_after: stuck_after) }
      end

      # THE PACK FILE, made the fastest way this machine has (as #run_fastest) and written to the
      # file at +path+, for the copy whose SHA-1 is +sha1+ and the build +build_version+: the bytes
      # #pack_file_in gives, whichever way played it. What an all-in-one build makes its pack with
      # (Builder::DataPacks#play_unpacking). Gives back the run, to ask whether the routine finished
      # and what went wrong (#finished_in?, #fault_in); a run as C (#write_pack_as_c) cannot be
      # asked for the pack's bytes, which are in the file and nowhere else.
      def write_pack_fastest(path, sha1:, build_version:, frames: most_frames, stuck_after: SECONDS_WITHOUT_FRAME)
        played = play_fastest(frames: frames, stuck_after: stuck_after) do
          write_pack_as_c(path, sha1: sha1, build_version: build_version, frames: frames, stuck_after: stuck_after)
        end
        File.binwrite(path, pack_file_in(played, sha1: sha1, build_version: build_version)) unless written_as_c?(played)
        played
      end

      # A run of the program built as C (IR::Backends::Native::FinalStateRun), optimised, handed the
      # copy, for at most +frames+ frames, read back as #run_as_ruby's is. The compiled program is
      # kept by its C, so the same routine is compiled once. Many times faster than the Ruby run on
      # a routine that works hard between frames. Computer::LoweringError where the C build cannot
      # make the program; a routine that waits for no frame for +stuck_after+ seconds is stopped,
      # as #run_as_ruby's is.
      def run_as_c(frames:, stuck_after: SECONDS_WITHOUT_FRAME)
        ended = IR::Backends::Native::FinalStateRun.new(stuck_after: stuck_after).run(program, frames: frames, file: copy_bytes)
        PackedRun.new(vars: ended.vars, lists: ended.lists, runner: :c)
      rescue IR::Backends::Native::FinalStateRun::Stuck
        raise stuck_routine_error(stuck_after)
      end

      # #run_as_c, writing the pack file (#pack_file_in's bytes) to +path+ as it ends. The pack's
      # header is written first and the C adds the list BYTES after it, so the pack is never read
      # back: held as numbers, a pack of hundreds of megabytes cost several times its size. The run
      # given back has every variable and list but BYTES.
      def write_pack_as_c(path, sha1:, build_version:, frames:, stuck_after: SECONDS_WITHOUT_FRAME)
        header = pack_header(sha1: sha1, build_version: build_version)
        File.binwrite(path, header)
        list_file = IR::Backends::Native::FinalStateRun::ListFile.new(name: BYTES, path: path)
        ended = IR::Backends::Native::FinalStateRun.new(stuck_after: stuck_after)
                                                   .run(program, frames: frames, file: copy_bytes, list_file: list_file)
        refuse_pack_file_of_wrong_size!(path, header.bytesize + byte_size + frame_records_size)
        PackedRun.new(vars: ended.vars, lists: ended.lists, runner: :c_pack_file)
      rescue IR::Backends::Native::FinalStateRun::Stuck
        raise stuck_routine_error(stuck_after)
      end

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
        state = game.state(byte_lists_packed: true)
        PackedRun.new(vars: state.vars.transform_keys(&:to_sym), lists: state.lists.transform_keys(&:to_sym), runner: :ruby)
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

      # A C or Ruby run's variables and lists, by the names a run of the interpreter is asked by, and
      # which runner played it (:c, :ruby, or :c_pack_file for #write_pack_as_c's, which wrote BYTES
      # to the pack file and does not hold it). Its lists of bytes are kept as binary Strings
      # (LiveGame#state's byte_lists_packed, FinalStateRun's lists one byte wide): #list gives one as
      # numbers, as the interpreter does, and #list_bytes as it is.
      PackedRun = Data.define(:vars, :lists, :runner) do
        def list(name)
          items = lists.fetch(name.to_sym)
          items.is_a?(String) ? items.unpack("c*") : items
        end

        def list_bytes(name) = lists.fetch(name.to_sym)
        def [](name) = vars.fetch(name.to_sym)
      end

      COPY = Messages::MadeNames.make(:unpacking_part, part: :copy)
      BYTES = Messages::MadeNames.make(:unpacking_part, part: :bytes)
      BYTES_DONE = Messages::MadeNames.make(:unpacking_part, part: :bytes_done)
      SLOT_BYTES_DONE = Messages::MadeNames.make(:unpacking_part, part: :slot_bytes_done)
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

      # How many bytes the pack's slots hold between them.
      def byte_size = slots.sum(&:byte_size)

      # Each slot's bytes, by name, in what +run+ (a run of #program, on any backend) wrote.
      def slot_bytes_in(run)
        bytes = bytes_in(run)
        places.to_h { |name, start| [name, bytes.byteslice(start, slot_named(name).byte_size)] }
      end

      # The frame records +run+ wrote after the slots (none for a game that names no frame).
      def frame_records_in(run) = bytes_in(run).byteslice(byte_size, frames.size)

      # The pack file +run+ made, for the copy whose SHA-1 is +sha1+ and the build +build_version+:
      # what a shell writes on a player's machine.
      def pack_file_in(run, sha1:, build_version:)
        Pack.holding(slot_bytes_in(run), sha1: sha1, build_version: build_version, frame_records: frame_records_in(run)).to_bytes
      end

      # The pack file's bytes up to the first slot's, for the copy whose SHA-1 is +sha1+ and the
      # build +build_version+: BYTES after it is the whole file.
      def pack_header(sha1:, build_version:)
        Pack.checked_header_bytes(slots.to_h { |slot| [slot.name, slot.byte_size] }, sha1: sha1, build_version: build_version)
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

      # The block's run as C where zig is installed, else #run_as_ruby's, else the interpreter's
      # (#run_fastest says why each).
      def play_fastest(frames:, stuck_after:)
        if IR::Backends::Native::Zig.installed?
          begin
            return yield
          rescue IR::Backends::Computer::LoweringError
            nil
          rescue IR::Backends::Computer::Error => e
            warn "The data pack's unpacking could not run as C, so it runs as Ruby, which is slower. " \
                 "This is a fault in VBlank: #{e.message.lines.first&.strip}"
          end
        end
        begin
          run_as_ruby(frames: frames, stuck_after: stuck_after)
        rescue IR::Backends::Ruby::RuntimeGap
          run_on(IR::Backends::Reference.new, frames: frames, max_steps: most_steps_a_frame)
        end
      end

      def written_as_c?(run) = run.is_a?(PackedRun) && run.runner == :c_pack_file

      # How many bytes of frame records BYTES holds after the slots.
      def frame_records_size = frames.size

      # The C wrote BYTES whole after the header, so the file is the header, the slots and the
      # frame records. BYTES is declared full at that length; a routine that shortened it writes a
      # file #pack_file_in would not, and that is a fault in VBlank, so the build plays it as Ruby.
      def refuse_pack_file_of_wrong_size!(path, wanted)
        written = File.size(path)
        return if written == wanted

        raise IR::Backends::Computer::Error, "the pack file written as C is #{written} bytes, and its header names #{wanted}"
      end

      # Everything +run+ wrote of the pack: the list BYTES, as a binary String.
      def bytes_in(run) = run.is_a?(PackedRun) ? run.list_bytes(BYTES) : run.list(BYTES).map { |item| item & 0xFF }.pack("C*")

      def stuck_routine_error(stuck_after)
        StuckRoutine.new(
          "The data pack's unpacking routine ran for #{stuck_after} seconds and did not wait for a frame. " \
          "Look for a loop in `slots.fill_from_copy` that never stops. If a long loop is correct, " \
          "call `wait_vblank` in it now and then."
        )
      end

      def start_watchdog(player, play_thread, stuck_after)
        error = stuck_routine_error(stuck_after)
        Thread.new do
          sleep(stuck_after / 4.0) until player.raise_if_stuck(play_thread, stuck_after, error)
        end
      end
    end
  end
end
