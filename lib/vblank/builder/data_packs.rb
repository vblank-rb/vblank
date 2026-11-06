# frozen_string_literal: true

module VBlank
  class Builder
    # THE ORIGINAL'S DATA, READ THROUGH A DATA PACK. A port of a retail game may not ship that
    # game's data, so it reads the player's own copy (Original::Game). It does not read the copy
    # directly: it says which pieces of the copy it needs, each a slot of a known shape and size,
    # and reads them from a data pack made from the copy (Original::Pack).
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.colors  :palette, at: 0x1000, count: 16
    #     slots.tiles   :walls,   at: 0x1020, count: 2
    #     slots.numbers :speeds,  at: 0x2000, count: 8, width: :byte, signed: false
    #   end
    #   image :wall, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
    #   speeds = table :speeds, pack[:speeds]
    #
    # Why a pack rather than the copy: the same port is built two ways. Built all-in-one, the pack
    # is made here as the game is built, and the game is built holding what it read from it. Built
    # as a shell, the player's machine makes the same pack from the player's copy and the game
    # reads it there. A slot's shape and size are the game's own words in either build, never
    # worked out from the bytes, so nothing the game's code does depends on what the copy holds.
    #
    # THE GAME HOLDS HANDLES, NEVER BYTES. `pack[:palette]` is a DSL::PackSlot, which says the slot's
    # shape and size and nothing it holds; `image` and `table` take the handle and read the slot
    # themselves (#pack_slot_values). So a game cannot branch on the original's bytes while it is
    # built, and a build that leaves the bytes out changes only what those verbs do with a handle.
    #
    # WHAT A BUILD DOES WITH THE PACK TODAY: every build is all-in-one. The pack is made from the
    # copy here, written as its file would be and read back from those bytes, so the game reads
    # exactly what a pack file holds; each verb given a handle then takes what the slot holds as if
    # the game had written it. So the interpreter, the cartridges and the builds for computers all
    # play the game as one that holds the data itself, and nothing below the builder knows a pack
    # was there. A cartridge stays this way for good: a console's cartridge holds its data, and
    # there is no player's machine to make a pack on. Only a computer's shell build will leave the
    # bytes out and read the pack as the game starts.
    #
    # A SLOT THE ORIGINAL KEEPS PACKED has no `at:`, and the game's own unpacking routine fills it:
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.colors :palette, at: 0x1000, count: 16
    #     slots.tiles  :walls, count: 40
    #     slots.fill_from_copy do |copy, pack|
    #       copy.unpack_lz77 at: 0x1020, into: pack[:walls]
    #     end
    #   end
    #
    # The routine is game code, not Ruby the build runs, so the same routine can make the pack on
    # a player's machine, where nothing but the shipped game runs. It is built into a program of
    # its own (#unpacking_program; Original::Unpacking says why one of its own, and what a shell
    # build must still add to play it there). Built all-in-one, that program is played to its end
    # here on the interpreter (#unpack_on_interpreter), and the pack is made from what it wrote;
    # every other backend plays the same program and is held to the interpreter's pack byte for
    # byte. Either way the game holds handles and reads the pack, as above.
    #
    # A game with no `data_pack` has no pack, and builds the same bytes as it did before there was one.
    module DataPacks
      # Make the game's data pack from the player's copy: +from+ is the Original::Game the port
      # names (or an Original::Copy already accepted), the block names the slots (DSL::PackSlots),
      # and +version+ names this build of the game in the pack's header, so a pack a player keeps is
      # made again when the game changes. Hands back a DSL::DataPack. A machine with no copy stops
      # here with Original::NotSet, saying what to set.
      def data_pack(from:, version: nil)
        refuse_second_data_pack!
        refuse_missing_pack_version!(version)
        copy = from.is_a?(Original::Copy) ? from : from.copy
        refuse_copy_without_hash!(copy)
        slots = DSL::PackSlots.new
        yield slots
        refuse_unfilled_slots!(slots)
        bytes = File.binread(copy.path)
        # Every slot copied as it is must lie inside the copy, whichever way the pack is made.
        copied = slots.list.reject(&:filled_by_routine?).to_h { |slot| [slot.name, slot.cut_from(bytes)] }
        unpacking = (unpacking_program(bytes, slots.list, slots.routine) if slots.routine)
        slot_bytes = unpacking ? unpack_on_interpreter(unpacking) : copied
        made = Original::Pack.holding(slot_bytes, sha1: copy.sha1, build_version: version)
        @data_pack_contents = Original::Pack.from_bytes(made.to_bytes)
        @data_pack_slots = slots.list.to_h { |slot| [slot.name, slot] }
        @data_pack = DSL::DataPack.new(@data_pack_contents, slots.list,
                                       make_unpacking: -> { unpacking || unpacking_program(bytes, slots.list, nil) })
      end

      private

      # THE UNPACKING PROGRAM (Original::Unpacking says why it is a program of its own): the copy's
      # +bytes+ as a table, the pack's bytes as one list, each of +slots+ copied as it is or filled
      # by +routine+, the game's `slots.fill_from_copy` block, run as game code on a builder of its
      # own. A pack with no routine has one too, which only copies: it is what a shell runs for any pack.
      def unpacking_program(bytes, slots, routine)
        Builder.keeping_builder_in_use do
          maker = Builder.new
          copy = maker.table(Original::Unpacking::COPY, bytes.bytes, width: :byte, signed: false)
          list = maker.list(Original::Unpacking::BYTES, capacity: slots.sum(&:byte_size), width: :byte, full_of: 0)
          finished = maker.var(Original::Unpacking::FINISHED, 0)
          faults = DSL::UnpackingFaults.new(maker)
          reader = DSL::OriginalBytes.new(maker, copy: copy, pack: list, faults: faults)
          places = Original::Unpacking.places_of(slots)
          writers = slots.each_with_index.to_h do |slot, number|
            [slot.name, DSL::SlotBytes.new(maker, list, slot, places[slot.name], number: number, faults: faults)]
          end
          pack = DSL::UnpackingSlots.new(writers)
          slots.reject(&:filled_by_routine?).each do |slot|
            reader.copy_bytes(at: slot.at, count: slot.byte_size, into: pack[slot.name])
          end
          maker.instance_exec(reader, pack, &routine) if routine
          finished.store!(1)
          maker.halt
          maker.finalize_program
          Original::Unpacking.new(program: maker.program, slots: slots, copy_size: bytes.bytesize)
        end
      end

      # How far a routine may go on the interpreter before it is taken to be stuck. A routine reads
      # each byte of the copy and writes each byte of the pack a few times at most, and waits for
      # the next frame at most once a byte; so the frames it can need, and the steps one frame can
      # take, follow from the two sizes. A routine past either is in a loop that does not end.
      UNPACKING_STEPS_A_BYTE = 64
      UNPACKING_SPARE_FRAMES = 100
      UNPACKING_SPARE_STEPS = 100_000

      def most_unpacking_frames(unpacking) = unpacking.copy_size + unpacking.byte_size + UNPACKING_SPARE_FRAMES

      def most_unpacking_steps_a_frame(unpacking)
        ((unpacking.copy_size + unpacking.byte_size) * UNPACKING_STEPS_A_BYTE) + UNPACKING_SPARE_STEPS
      end

      # Each slot's bytes as +unpacking+ writes them on the interpreter, the answer key every other
      # backend is held to. The first fault the routine met (a block not packed the way it says, a
      # read past the copy's end, a write past a slot) stops the build here, as a slot past the
      # copy's end does.
      def unpack_on_interpreter(unpacking)
        most_frames = most_unpacking_frames(unpacking)
        ran = begin
          IR::Backends::Reference.new.run(unpacking.program, frames: most_frames,
                                                             max_steps: most_unpacking_steps_a_frame(unpacking))
        rescue IR::ProgramError => e
          raise ArgumentError, "The data pack's unpacking routine went wrong as it ran. #{e.message}"
        end
        fault = unpacking.fault_in(ran)
        raise fault.error(unpacking.slots, unpacking.copy_size) if fault
        unless unpacking.finished_in?(ran)
          raise ArgumentError, "The data pack's unpacking routine did not get to its end in #{most_frames} frames. " \
                               "A routine must end. Look for a loop in `slots.fill_from_copy` that never stops."
        end

        unpacking.slot_bytes_in(ran)
      end

      def refuse_unfilled_slots!(slots)
        return if slots.routine

        unfilled = slots.list.select(&:filled_by_routine?).map { |slot| ":#{slot.name}" }
        return if unfilled.empty?

        raise ArgumentError, "Slot #{unfilled.join(', ')} has no at:, and the data pack has no `slots.fill_from_copy` " \
                             "routine. Nothing fills it. Give the slot its place in the copy with at:, or fill it in " \
                             "`slots.fill_from_copy do |copy, pack| ... end`."
      end

      # What the slot +handle+ (a DSL::PackSlot) holds, read as +wanted+ asks: :colors and :numbers
      # take a whole slot of that shape, :tile one tile of a slot of tiles. +where+ names the line
      # for the error ("image :wall's colors:").
      def pack_slot_values(handle, wanted, where)
        refuse_slot_from_elsewhere!(handle, where)
        refuse_slot_read_wrongly!(handle, wanted, where)
        values = handle.layout.decode(@data_pack_contents.bytes_of(handle.layout.name))
        handle.one_tile? ? values.fetch(handle.tile_index) : values
      end

      # +opts+ for `image`, each handle in colors: or places: replaced by what its slot holds.
      def opts_with_pack_slots_read(name, opts)
        read = opts.dup
        read[:colors] = pack_slot_values(opts[:colors], :colors, "image :#{name}'s colors:") if opts[:colors].is_a?(DSL::PackSlot)
        read[:places] = pack_slot_values(opts[:places], :tile, "image :#{name}'s places:") if opts[:places].is_a?(DSL::PackSlot)
        read
      end

      def refuse_second_data_pack!
        return if @data_pack.nil?

        raise ArgumentError, "The game says `data_pack` twice. A game has one data pack. Name every slot in one " \
                             "`data_pack` block."
      end

      def refuse_missing_pack_version!(version)
        return unless version.nil?

        raise ArgumentError, "`data_pack` needs version:. It names this build of the game in the pack. A player's " \
                             "pack is made again when the version changes. Write `data_pack from: ..., " \
                             "version: \"1.0\"`, and change the version when the game's data changes."
      end

      def refuse_copy_without_hash!(copy)
        return if copy.sha1

        raise ArgumentError, "#{copy.path} is a folder, so it has no one SHA-1. A data pack is made from a copy that " \
                             "is one file. Name the file of your copy."
      end

      def refuse_slot_from_elsewhere!(handle, where)
        return if @data_pack_slots&.fetch(handle.layout.name, nil) == handle.layout

        raise ArgumentError, "#{where} was given slot :#{handle.layout.name}, and this game's data pack has no such slot. " \
                             "Use a slot from this game's `data_pack`."
      end

      # What each way of reading a slot needs, in words, for the error.
      SLOT_READING_WORDS = { colors: "a slot of colors", tile: "one tile, like `pack[:walls].tile(0)`",
                             numbers: "a slot of numbers" }.freeze

      def refuse_slot_read_wrongly!(handle, wanted, where)
        fits = wanted == :tile ? handle.one_tile? : handle.shape == wanted && !handle.one_tile?
        return if fits

        given = handle.one_tile? ? "one tile of slot :#{handle.layout.name}" : "slot :#{handle.layout.name}, which holds #{handle.shape}"
        raise ArgumentError, "#{where} was given #{given}. It must be given #{SLOT_READING_WORDS.fetch(wanted)}."
      end
    end
  end
end
