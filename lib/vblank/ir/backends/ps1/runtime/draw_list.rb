# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE LIST OF DRAWING COMMANDS. The graphics chip draws whatever reaches its GP0 port, and the
          # port's queue holds sixteen words. Fed by the processor a word at a time, the processor waits
          # whenever the queue is full, which is whenever the chip has more to draw than the processor has
          # to work out: four backgrounds the size of the screen kept it waiting most of every frame.
          #
          # So every command goes into a list in RAM instead (rt_draw_command_1 and its siblings, one for
          # each length a command can have), and the DMA controller hands the list to the chip while the
          # processor goes on. That is how the console's own games drew: they built a list of commands in
          # RAM each frame, and the DMA followed it to the chip (psx-spx, "DMA Channels"; the libraries'
          # DrawOTag). The DMA lets the processor run while it waits for the chip (Beetle PSX measured: a
          # loop of the processor's own ran no slower while a list of fills was being sent, and the wait for
          # the DMA came after it).
          #
          # A LINKED LIST, A NODE A COMMAND, as the console's games built theirs: each command is a header
          # word, how many words follow in its top byte and where the next node is in its low 24 bits, then
          # the command. The DMA asks the chip for room before each node and then hands it the whole node,
          # so the chip always has a whole command to draw. (A list sent a word at a time stops for good
          # inside a textured rectangle in Beetle PSX: the chip asks for no more words until it holds the
          # whole command.) The addresses are RAM's own, below 2 megabytes, where the processor reaches the
          # same bytes as at 80000000h, so a node's next address is the cursor itself, with no masking.
          #
          # TWO LISTS, one sent while the other is filled. When the one being filled has no room for another
          # command, it is ended and sent (rt_draw_list_send): the processor first waits for the other to be
          # gone, then starts this one and goes on filling the other. A pass's last commands are sent where
          # the pass ends (rt_draw_list_finish), which waits for the chip to have taken all of them, so the
          # pass's picture is whole before it is shown or read back (Frame).
          #
          # EVERYTHING ELSE THAT REACHES THE CHIP waits for the list first, so it comes after every command
          # sent before it: the copies of the pictures into video RAM at power-on (Paint's rt_paint_upload,
          # which sends their pixels by the same DMA), a place's faces, which go to the port
          # (Faces#emit_port_command says why), a change of the page shown (Paint's rt_paint_screen, Frame's
          # rt_show_pass) and the end of the game (Frame's rt_stop_with_state).
          #
          # A COMMAND IS SENT as its first word in a0 and a jump to the routine for its length, which
          # leaves t1 holding where that word went; its other words are stored after it, at
          # #word_offset_bytes(1), (2) and on. The routine changes only t1 to t3, so the words after the
          # first can be worked out before it is called.
          module DrawList
            h = Console::PS1Hardware

            # The lengths in words a command in the list can have, each with its routine: one word (a setting,
            # or the cache emptied), a fill or a flat rectangle (three), a textured rectangle or a copy inside
            # video RAM (four). A place's triangles go to the port (Faces#emit_port_command).
            COMMAND_WORDS = [1, 3, 4].freeze

            # A node's header, before its command.
            HEADER_BYTES = 4
            MOST_NODE_BYTES = HEADER_BYTES + (COMMAND_WORDS.max * 4)
            # The header of the node that ends a list: no words, and no node after it (psx-spx, "DMA").
            END_NODE = 0x00FF_FFFF

            # Each list's room. A list is sent once it is full, so the chip starts drawing a pass's first
            # commands while the processor is still at the pass's later ones; the smaller the list, the
            # sooner it starts, and the more often a list is sent.
            LIST_BYTES = 2048

            # The two lists, one after the other in the region (#reserve_late).
            LISTS = "draw lists"

            # RAM's own addresses, which a node's header and the DMA take: the processor's address less its
            # segment's top bits.
            PHYSICAL_MASK = 0x1FFF_FFFF

            # THE LIST'S STATE, a word each in one block of the region: where the next node goes in the list
            # being filled, the last place a node may start in it (room for the longest, and for the node that
            # ends it), where it starts, and where the other one starts; then where a full list, and
            # rt_draw_list_finish, keep their return addresses while they send, so neither needs the stack,
            # which is the scratchpad's own while a face is filled (Faces::FILL_STACK).
            #
            # Must be asked for after the game's numbers (#reserve_late): asked for first, it pushes some of
            # them out of gp's reach (Memory), where each costs an instruction more wherever it is read. Each
            # routine reaches the block from a register given the top half of its address.
            STATE_BLOCK = "draw list state"
            CURSOR_OFFSET_BYTES = 0
            LIMIT_OFFSET_BYTES = 4
            START_OFFSET_BYTES = 8
            OTHER_OFFSET_BYTES = 12
            SAVED_RETURN_OFFSET_BYTES = 16
            FINISH_RETURN_OFFSET_BYTES = 20
            STATE_BYTES = 24

            LIMIT_BYTES = LIST_BYTES - MOST_NODE_BYTES - HEADER_BYTES

            DMA_BUSY_BIT = 24 # CHCR's bit set while the DMA is sending (Console::PS1Hardware::DMA_BUSY)
            raise "DMA_BUSY is not bit #{DMA_BUSY_BIT}" unless h::DMA_BUSY == 1 << DMA_BUSY_BIT

            # Where the state is, as an instruction reaches it: the top half of its address for a LUI, and
            # the bottom half, signed, as the distance from it.
            StatePlace = Data.define(:high, :low) do
              def self.for_address(address)
                high = ((address + 0x8000) >> 16) & 0xFFFF
                new(high: high, low: address - (high << 16))
              end

              # The distance of the word at +offset+ in the block.
              def at(offset) = low + offset
            end

            module_function

            # The state and the two lists, asked for once the game's numbers have their places; the region
            # cleared at power-on takes them in.
            def reserve_late(memory)
              memory.reserve(STATE_BLOCK, STATE_BYTES)
              memory.reserve(LISTS, LIST_BYTES * 2)
            end

            # WHERE A COMMAND IN THE LIST TELLS THE FACES OF A PLACE TO WAIT FOR IT. A face's commands go to
            # the port (Faces#emit_port_command), so before its first the list must be sent and drawn. A face
            # sends the chip's texture window first, unless the last face sent the same one (Faces'
            # CHIP_OFFSET_BYTES keeps it); so every command put in the list sets that kept window to nought,
            # which no window is, and a face sending its window has the list drawn first. Most faces show the
            # picture the last did, and pay nothing for this. The kept window's distance from fp, for a game
            # that fills faces.
            def face_window_offset_bytes(memory) = Memory.distance_from_scratchpad(memory[Faces::FACE]) + Faces::CHIP_OFFSET_BYTES

            # Where the word +index+ of a command (0 its first) goes, from t1 as the command's routine leaves it.
            def word_offset_bytes(index) = index * 4

            # A jump to the routine that sends a command of +words+ words, its first in a0; +slot+ for the
            # jump's delay slot, as R3000#jal takes it.
            def emit_command(asm, words, &slot)
              raise ArgumentError, "no GP0 command is #{words} words long" unless COMMAND_WORDS.include?(words)

              asm.jal("rt_draw_command_#{words}", &slot)
            end

            # +faces+ is whether the game fills faces (#face_window_offset_bytes).
            def emit(asm, memory, faces:)
              state = StatePlace.for_address(memory[STATE_BLOCK])
              face_window = faces ? face_window_offset_bytes(memory) : nil
              emit_start(asm, memory, state)
              COMMAND_WORDS.each { |words| emit_command_routine(asm, state, face_window, words) }
              emit_send(asm, state)
              emit_kick(asm)
              emit_finish(asm, state)

            end

            # rt_draw_list_start: the first list to be filled, the DMA's channel for the chip on, and the chip
            # told to take words from it.
            def emit_start(asm, memory, state)
              h = Console::PS1Hardware
              first = memory[LISTS] & PHYSICAL_MASK
              asm.label("rt_draw_list_start")
              asm.lui(:t2, state.high)
              asm.li(:t0, first)
              asm.sw(:t0, state.at(START_OFFSET_BYTES), :t2)
              asm.sw(:t0, state.at(CURSOR_OFFSET_BYTES), :t2)
              asm.li(:t0, first + LIMIT_BYTES)
              asm.sw(:t0, state.at(LIMIT_OFFSET_BYTES), :t2)
              asm.li(:t0, first + LIST_BYTES)
              asm.sw(:t0, state.at(OTHER_OFFSET_BYTES), :t2)
              asm.lui(:t1, h::IO >> 16)
              asm.lw(:t0, h::DPCR & 0xFFFF, :t1)
              asm.ori(:t0, :t0, h::DPCR_GPU_ON)
              asm.sw(:t0, h::DPCR & 0xFFFF, :t1)
              asm.li(:t0, h::GP1_DMA_DIRECTION | h::DMA_TO_GP0)
              asm.jr(:ra) { asm.sw(:t0, h::GP1 & 0xFFFF, :t1) }
            end

            # rt_draw_command_N: a0 = the first word of a command N words long, put in the list as a node of
            # its own; t1 = where that word went. The node's header names the place after the node as the
            # next, where the next node goes, or the node that ends the list once it is sent.
            def emit_command_routine(asm, state, face_window, words)
              node_bytes = HEADER_BYTES + (words * 4)
              label = "rt_draw_command_#{words}"
              asm.label(label)
              asm.lui(:t3, state.high)
              asm.lw(:t1, state.at(CURSOR_OFFSET_BYTES), :t3)
              asm.lw(:t3, state.at(LIMIT_OFFSET_BYTES), :t3)
              asm.addiu(:t2, :t1, node_bytes)
              asm.sltu(:t3, :t3, :t1)
              asm.bne(:t3, :zero, "#{label}_full") { asm.lui(:t3, words << 8) }
              asm.or(:t3, :t3, :t2)
              asm.sw(:t3, 0, :t1)
              asm.sw(:a0, HEADER_BYTES, :t1)
              asm.lui(:t3, state.high)
              asm.sw(:t2, state.at(CURSOR_OFFSET_BYTES), :t3)
              asm.sw(:zero, face_window, :fp) if face_window
              asm.jr(:ra) { asm.addiu(:t1, :t1, HEADER_BYTES) }

              # No room for the node: the list is sent, and the node goes into the other.
              asm.label("#{label}_full")
              asm.lui(:t3, state.high)
              asm.sw(:ra, state.at(SAVED_RETURN_OFFSET_BYTES), :t3)
              asm.jal("rt_draw_list_send")
              asm.lui(:t3, state.high)
              asm.lw(:ra, state.at(SAVED_RETURN_OFFSET_BYTES), :t3)
              asm.b(label)
            end

            # rt_draw_list_send: the list being filled ended and sent, unless it is empty, once the DMA has
            # finished sending the other; then the other is the one filled. Changes only t1 to t3.
            def emit_send(asm, state)
              h = Console::PS1Hardware
              asm.label("rt_draw_list_send")
              asm.lui(:t3, state.high)
              asm.lw(:t2, state.at(START_OFFSET_BYTES), :t3)
              asm.lw(:t1, state.at(CURSOR_OFFSET_BYTES), :t3)
              asm.beq(:t1, :t2, "rt_draw_list_send_done")
              asm.li(:t3, END_NODE)
              asm.sw(:t3, 0, :t1)
              asm.lui(:t1, h::IO >> 16)
              emit_dma_wait(asm, "rt_draw_list_send_wait")
              asm.sw(:t2, h::DMA2_MADR & 0xFFFF, :t1)
              asm.li(:t3, h::DMA2_FROM_RAM_BY_LIST)
              asm.sw(:t3, h::DMA2_CHCR & 0xFFFF, :t1)
              asm.lui(:t1, state.high)
              asm.lw(:t3, state.at(OTHER_OFFSET_BYTES), :t1)
              asm.sw(:t2, state.at(OTHER_OFFSET_BYTES), :t1)
              asm.sw(:t3, state.at(START_OFFSET_BYTES), :t1)
              asm.sw(:t3, state.at(CURSOR_OFFSET_BYTES), :t1)
              asm.addiu(:t3, :t3, LIMIT_BYTES)
              asm.sw(:t3, state.at(LIMIT_OFFSET_BYTES), :t1)
              asm.label("rt_draw_list_send_done")
              asm.jr(:ra)
            end

            # rt_draw_list_kick: the list being filled sent now if the DMA is free, and left to fill if it is
            # not. Called after a command the chip takes long to draw (a fill of the screen, a background),
            # so the chip starts on it while the processor goes on, and is not left with nothing to draw
            # until the list fills or the pass ends. Changes only t1 to t3.
            def emit_kick(asm)
              h = Console::PS1Hardware
              asm.label("rt_draw_list_kick")
              asm.lui(:t1, h::IO >> 16)
              emit_dma_busy(asm)
              asm.beq(:t3, :zero, "rt_draw_list_send")
              asm.jr(:ra)
            end

            # Wait at +label+ until the DMA has sent all it was given; t1 holds the ports' base. Changes t3.
            def emit_dma_wait(asm, label)
              asm.label(label)
              emit_dma_busy(asm)
              asm.bne(:t3, :zero, label)
            end

            # t3 = 1 while the DMA is sending, 0 once it is free; t1 holds the ports' base.
            def emit_dma_busy(asm)
              asm.lw(:t3, Console::PS1Hardware::DMA2_CHCR & 0xFFFF, :t1)
              asm.srl(:t3, :t3, DMA_BUSY_BIT)
              asm.andi(:t3, :t3, 1)
            end

            # rt_draw_list_finish: everything in the lists sent, and drawn: the DMA done, then the chip idle
            # with its queue empty (Console::PS1Hardware::GPUSTAT_DRAWN). Changes only t1 to t3.
            def emit_finish(asm, state)
              h = Console::PS1Hardware
              asm.label("rt_draw_list_finish")
              asm.lui(:t1, state.high)
              asm.sw(:ra, state.at(FINISH_RETURN_OFFSET_BYTES), :t1)
              asm.jal("rt_draw_list_send")
              asm.lui(:t1, h::IO >> 16)
              emit_dma_wait(asm, "rt_draw_list_finish_wait")
              asm.lui(:t2, h::GPUSTAT_DRAWN >> 16)
              asm.label("rt_draw_list_drawn_wait")
              asm.lw(:t3, h::GP1 & 0xFFFF, :t1)
              asm.and(:t3, :t3, :t2)
              asm.bne(:t3, :t2, "rt_draw_list_drawn_wait")
              asm.lui(:t1, state.high)
              asm.lw(:ra, state.at(FINISH_RETURN_OFFSET_BYTES), :t1)
              asm.jr(:ra)
            end
          end
        end
      end
    end
  end
end
