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
    # the routine runs as the game is built, on the interpreter, the answer key
    # (Builder::DataPacks#unpack_on_interpreter), and the pack is made from what it wrote. A
    # cartridge never carries the routine.
    #
    # The routine is ordinary game code, made of the verbs and IR every backend already plays (a
    # table, a byte list, loops, routines, `wait_vblank`, `halt`), so every run plays it as it plays
    # any game, checked against the interpreter, and nothing new is asked of a backend.
    #
    # BUILT WITH THE PACK LEFT OUT. Built all-in-one, the copy is a table of constants made from
    # the copy's file as the game is built. A build that leaves the pack out (`pack_at_start:`,
    # Builder::DataPacks) has no copy and must not hold the original's bytes, so its program is
    # built for a copy of a known size (`pack.unpacking(copy_size:)`, the release's size) and COPY
    # is read from the file it is handed as it starts (IR::StartFile): the player's copy. Played to
    # its `halt` on any computer's runtime handed that file, BYTES read back after it is the pack.
    # The routine itself does not change for any of that. What a shell must still add is playing it
    # inside the shipped game before the game, and keeping the pack it wrote.
    #
    # WHAT IS IN IT. The copy is a table of bytes (COPY). The pack is one list of bytes (BYTES),
    # every slot in it one after another in the pack's order (#places), as the pack file keeps them.
    # The slots copied as they are (`at:`) are copied first, then the routine runs, then FINISHED is
    # set and the program halts. The building blocks (CopyReader, Packing::BlockKit) add what they
    # write to BYTES_DONE as they go and wait for the next frame every so often, so a shell can show
    # how far the unpacking has got. The first thing that goes wrong (Fault) is kept in the FAULT_
    # variables and nothing after it overwrites it. +format_words+ are what a person calls each
    # format the copy offered, in the order a fault numbers them.
    Unpacking = Data.define(:program, :slots, :copy_size, :format_words)

    class Unpacking
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
    end
  end
end
