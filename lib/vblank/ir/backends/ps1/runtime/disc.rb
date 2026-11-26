# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # Reading a group of tables from the disc into its room (TableRooms), for a game that keeps
          # tables in groups.
          #
          # The drive is told how to read (Setmode: double speed, 2048 bytes of each sector), where to
          # start (Setloc, the place as minute, second and sector), and to read (ReadN). From then on it
          # reads a sector at a time, 150 a second, and raises its interrupt for each one ready. The
          # processor asks for the sector's bytes and the DMA's channel 3 moves them into RAM, 2048 at
          # once. When the last is in, Pause stops the drive (psx-spx, "CDROM Controller Command
          # Summary", "DMA Channels"). That is how the console's own games read their data: a level's
          # sectors read one after another from a place known before the read, each sent to RAM by the
          # DMA, while the game waits for the last.
          #
          # The drive's interrupt never reaches the processor (the runtime lets only its own through,
          # Boot): the routine asks the drive's flags until they say what it waits for. The blank's
          # interrupt goes on while it waits, so the music plays on and the pads are read.
          #
          # A sector the drive could not read raises its error interrupt, and the read starts again from
          # the group's first sector, as the console's own games tried again until the read worked.
          #
          # Loading the group already loaded reads nothing: the room holds it still, since the game never
          # writes a table.
          module Disc
            module_function

            # rt_disc_load: a0 the group's number, a1 the address of its set's entries (TableRooms#entries,
            # two words a group: the place, then the sectors), a2 how many groups the set has, a3 the place
            # keeping which group is loaded (its number and one, nought for none), t4 the room's address.
            def emit(asm)
              h = Console::PS1Hardware
              asm.label("rt_disc_load")
              asm.sltu(:t0, :a0, :a2) # a number naming no group (or below nought) loads nothing
              asm.beq(:t0, :zero, "rt_disc_done")
              asm.lw(:t1, 0, :a3)
              asm.addiu(:t2, :a0, 1)
              asm.beq(:t1, :t2, "rt_disc_done")
              asm.sll(:t0, :a0, 3)
              asm.addu(:t0, :a1, :t0)
              asm.lw(:t5, 0, :t0) # where, for Setloc
              asm.lw(:t6, 4, :t0) # how many sectors
              asm.sw(:t2, 0, :a3)
              asm.beq(:t6, :zero, "rt_disc_done")
              asm.lui(:t8, h::IO >> 16)
              asm.lw(:t0, port(h::DPCR), :t8)
              asm.li(:t1, h::DPCR_CDROM_ON)
              asm.or(:t0, :t0, :t1)
              asm.sw(:t0, port(h::DPCR), :t8)

              asm.label("rt_disc_again")
              asm.move(:t7, :t4) # where the next sector goes
              asm.move(:t9, :t6) # sectors still to read
              emit_command(asm, "setmode", h::CD_SETMODE, [->(reg) { asm.li(reg, h::CD_DOUBLE_SPEED_DATA) }])
              emit_wait_for(asm, "setmode", h::CD_ACKNOWLEDGED)
              emit_command(asm, "setloc", h::CD_SETLOC, [->(reg) { asm.andi(reg, :t5, 0xFF) },
                                                         ->(reg) { asm.srl(reg, :t5, 8); asm.andi(reg, reg, 0xFF) },
                                                         ->(reg) { asm.srl(reg, :t5, 16) }])
              emit_wait_for(asm, "setloc", h::CD_ACKNOWLEDGED)
              emit_command(asm, "readn", h::CD_READN, [])
              emit_wait_for(asm, "readn", h::CD_ACKNOWLEDGED)

              asm.label("rt_disc_sector")
              emit_wait_for(asm, "sector", h::CD_SECTOR_READY)
              emit_index(asm, 0)
              asm.sb(:zero, port(h::CD_REQUEST), :t8)
              asm.li(:t0, h::CD_WANT_DATA)
              asm.sb(:t0, port(h::CD_REQUEST), :t8)
              # The DMA starts once the sector's bytes are in the data FIFO (psx-spx, "CDROM Controller
              # I/O Ports": status bit 6), or a real drive can hand it a short or stale sector.
              asm.label("rt_disc_data_wait")
              asm.lbu(:t0, port(h::CD_INDEX), :t8)
              asm.andi(:t0, :t0, h::CD_DATA_WAITING)
              asm.beq(:t0, :zero, "rt_disc_data_wait")
              asm.sw(:t7, port(h::DMA3_MADR), :t8)
              asm.li(:t0, h::DMA3_ONE_SECTOR)
              asm.sw(:t0, port(h::DMA3_BCR), :t8)
              asm.li(:t0, h::DMA3_TO_RAM_NOW)
              asm.sw(:t0, port(h::DMA3_CHCR), :t8)
              asm.lui(:t1, h::DMA_BUSY >> 16)
              asm.label("rt_disc_moving")
              asm.lw(:t0, port(h::DMA3_CHCR), :t8)
              asm.and(:t0, :t0, :t1)
              asm.bne(:t0, :zero, "rt_disc_moving")
              asm.addiu(:t9, :t9, -1)
              asm.bne(:t9, :zero, "rt_disc_sector") { asm.addiu(:t7, :t7, Cartridge::PS1Disc::SECTOR) }

              emit_command(asm, "pause", h::CD_PAUSE, [])
              emit_wait_for(asm, "pause", h::CD_ACKNOWLEDGED)
              emit_wait_for(asm, "paused", h::CD_COMPLETE)
              asm.label("rt_disc_done")
              asm.jr(:ra)
            end

            # The distance of +address+ from 1F800000h, held in t8.
            def port(address) = address & 0xFFFF

            def emit_index(asm, index)
              if index.zero?
                asm.sb(:zero, port(Console::PS1Hardware::CD_INDEX), :t8)
              else
                asm.li(:t0, index)
                asm.sb(:t0, port(Console::PS1Hardware::CD_INDEX), :t8)
              end
            end

            # Sends +command+ (+name+ names its labels) once the drive has taken the last, with every interrupt seen and no
            # parameter left over first; each of +parameters+ puts its byte in the register it is handed.
            def emit_command(asm, name, command, parameters)
              h = Console::PS1Hardware
              ready = "rt_disc_#{name}_ready"
              asm.label(ready)
              asm.lbu(:t0, port(h::CD_INDEX), :t8)
              asm.andi(:t0, :t0, h::CD_BUSY)
              asm.bne(:t0, :zero, ready)
              emit_index(asm, 1)
              asm.li(:t0, h::CD_ACKNOWLEDGE_ALL)
              asm.sb(:t0, port(h::CD_REQUEST), :t8)
              asm.li(:t0, h::CD_CLEAR_PARAMETERS)
              asm.sb(:t0, port(h::CD_REQUEST), :t8)
              emit_index(asm, 0)
              parameters.each do |parameter|
                parameter.call(:t1)
                asm.sb(:t1, port(h::CD_PARAMETER), :t8)
              end
              asm.li(:t0, command)
              asm.sb(:t0, port(h::CD_COMMAND), :t8)
            end

            # Waits for the drive's interrupt +kind+ (+name+ names its labels), seeing every other one on the way; its response is
            # read and thrown away. An error starts the read again.
            def emit_wait_for(asm, name, kind)
              h = Console::PS1Hardware
              again = "rt_disc_#{name}_wait"
              drain = "#{again}_drain"
              drained = "#{again}_drained"
              asm.label(again)
              emit_index(asm, 1)
              asm.lbu(:t0, port(h::CD_REQUEST), :t8)
              asm.andi(:t0, :t0, 7)
              asm.beq(:t0, :zero, again)
              asm.label(drain)
              asm.lbu(:t1, port(h::CD_INDEX), :t8)
              asm.andi(:t1, :t1, h::CD_RESPONSE_WAITING)
              asm.beq(:t1, :zero, drained)
              asm.lbu(:t1, port(h::CD_COMMAND), :t8)
              asm.b(drain)
              asm.label(drained)
              asm.li(:t1, h::CD_ACKNOWLEDGE_ALL)
              asm.sb(:t1, port(h::CD_REQUEST), :t8)
              asm.li(:t1, h::CD_ERROR)
              asm.beq(:t0, :t1, "rt_disc_again")
              asm.li(:t1, kind)
              asm.bne(:t0, :t1, again)
            end
          end
        end
      end
    end
  end
end
