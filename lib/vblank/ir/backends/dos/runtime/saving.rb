# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        module Runtime
          # SAVE MEMORY, KEPT IN A FILE BESIDE THE PROGRAM. A console's cartridge has a chip a battery keeps;
          # a PC has a disk. The game's save memory is the 32K the interpreter's is (IR::SaveLayout), a byte
          # for a byte, so a save made by one starts the other. The program keeps all of it in memory, in a
          # segment of its own, and the file is the same bytes on the disk.
          #
          # AS THE PROGRAM STARTS (rt_save_start) it works out the file's name, fills the 32K with FFh (what
          # save memory nobody has written reads as), and reads the file over it if there is one.
          #
          # THE FILE'S NAME is the program's own with SAV for its last part, GAME.SAV beside GAME.EXE, wherever
          # the program was started from. DOS hands a program its own whole path after the last of its
          # environment's strings: the environment's segment is the word at 2Ch of the PSP, the strings end
          # with an empty one, and a word holding 1 and then the path follow. A program started with no
          # environment, or by a DOS too old to give the path, saves in GAME.SAV where it was started from.
          #
          # A READ OR A CHECKSUM never touches the disk: it reads the 32K in memory. A WRITE changes the
          # memory and marks the bytes it changed. THE DISK IS WRITTEN ONCE A PASS, as the pass ends and the
          # game has nothing to do but wait (rt_save_flush, also where the game stops): the file opened,
          # every byte from the first changed to the last written in one go, and the file shut, so what is
          # on the disk is the save whenever the PC is switched off between passes. A disk is thousands of
          # times slower than memory, and a game that keeps twenty numbers as it starts, or one every pass,
          # would otherwise open and shut the file for each. A file that is not there, or is shorter than the
          # 32K (a write the power cut short), is made whole.
          #
          # A DISK THAT CANNOT BE WRITTEN leaves the game playing with its save in memory. DOS's own answer
          # to such a disk is to stop and ask the player "Abort, Retry, Fail?" through an interrupt (24h),
          # over the game's picture and waiting for a key the game's keyboard routine never passes on. So the
          # runtime answers that interrupt itself, with "fail", and the write comes back as one that could not.
          #
          # DOS's calls are made through interrupt 21h with the call's number in AH: 3Ch makes a file, 3Dh
          # opens one, 3Eh shuts one, 3Fh reads, 40h writes and 42h moves to a place in it. Each sets the
          # carry flag when it could not, and hands back the file's handle in AX where it opens one.
          #
          # A place outside the 32K stops the game in the interpreter's words (Faults.save_outside).
          module Saving
            SIZE = SaveLayout::SIZE
            NAME = "rt save name"
            NAME_ROOM = 128
            # The bytes changed since the disk was last written: from the first, up to and not the last's
            # place. Nothing changed is from the 32K's end to nought.
            CHANGED_FROM = "rt save changed from"
            CHANGED_TO = "rt save changed to"
            # 1 when the file on the disk is not the whole 32K, so the next write makes it whole.
            NOT_WHOLE = "rt save not whole"

            DOS_CALL = 0x21
            MAKE_FILE = 0x3C
            OPEN_FILE = 0x3D
            SHUT_FILE = 0x3E
            READ_FILE = 0x3F
            WRITE_FILE = 0x40
            MOVE_IN_FILE = 0x42
            OPENED_TO_WRITE = 1
            # Where in the PSP the segment of the program's environment is.
            PSP_ENVIRONMENT = 0x2C
            # ".SAV" as the four bytes it is, lowest first, and the name of a program whose own is not known.
            DOT_SAV = ".SAV".unpack1("V")
            GAME = "GAME".unpack1("V")
            # The interrupt DOS asks "Abort, Retry, Fail?" through, where its routine is kept, and the
            # answer "fail" a routine gives it in AL.
            CRITICAL_ERROR_VECTOR = 0x24 * 4
            FAIL = 3

            module_function

            def reserve(memory)
              memory.reserve(NAME, NAME_ROOM)
              memory.reserve(CHANGED_FROM, 4)
              memory.reserve(CHANGED_TO, 4)
              memory.reserve(NOT_WHOLE, 4)
            end

            def emit(asm, memory)
              emit_start(asm, memory)
              emit_inside_or_stop(asm, memory)
              emit_read(asm)
              emit_write(asm, memory)
              emit_flush(asm, memory)
              emit_sum(asm)
            end

            # rt_save_start, with the PSP's segment in BP. Changes AX, BX, CX, DX, SI and DI.
            def emit_start(asm, memory)
              name = memory[NAME]
              asm.label("rt_save_start")
              asm.push(:es)
              emit_critical_error_answer(asm)
              asm.mov(:es, :bp)
              asm.mov(:ax, X86.mem(nil, PSP_ENVIRONMENT, seg: :es))
              asm.test(:ax, :ax)
              asm.je("rt_save_no_path")
              asm.mov(:es, :ax)
              # Past the environment's strings: to the two noughts that end them, then the word after,
              # which is 1 when the program's path follows.
              asm.xor(:di, :di)
              asm.label("rt_save_environment")
              asm.cmp(X86.mem(:di, 0, seg: :es, size: 16), 0)
              asm.je("rt_save_path")
              asm.inc(:di)
              asm.jmp("rt_save_environment")
              asm.label("rt_save_path")
              asm.cmp(X86.mem(:di, 2, seg: :es, size: 16), 1)
              asm.jne("rt_save_no_path")
              asm.add(:di, 4)
              # The path copied, SI kept at the last dot of its last part (a dot before a backslash is a folder's).
              asm.mov(:bx, name)
              asm.xor(:si, :si)
              asm.label("rt_save_copy")
              asm.mov(:al, X86.mem(:di, 0, seg: :es))
              asm.mov(X86.mem(:bx, 0), :al)
              asm.test(:al, :al)
              asm.je("rt_save_copied")
              asm.cmp(:al, ".".ord)
              asm.jne("rt_save_not_dot")
              asm.mov(:si, :bx)
              asm.label("rt_save_not_dot")
              asm.cmp(:al, "\\".ord)
              asm.jne("rt_save_not_folder")
              asm.xor(:si, :si)
              asm.label("rt_save_not_folder")
              asm.inc(:di)
              asm.inc(:bx)
              asm.cmp(:bx, name + NAME_ROOM - 5)
              asm.jb("rt_save_copy")
              asm.label("rt_save_copied")
              asm.test(:si, :si)
              asm.jne("rt_save_named")
              asm.mov(:si, :bx)
              asm.jmp("rt_save_named")
              asm.label("rt_save_no_path")
              asm.mov(X86.mem(nil, name, size: 32), GAME)
              asm.mov(:si, name + 4)
              asm.label("rt_save_named")
              asm.mov(X86.mem(:si, 0, size: 32), DOT_SAV)
              asm.mov(X86.mem(:si, 4, size: 8), 0)
              emit_load(asm, memory)
              asm.pop(:es)
              asm.ret
            end

            # The 32K as nobody has written it, then the file over it, and nothing marked as changed. A file
            # that is not there or is short of the 32K is one the first write makes whole.
            def emit_load(asm, memory)
              asm.mov_segment(:ax, :save)
              asm.mov(:es, :ax)
              asm.xor(:di, :di)
              asm.mov(:cx, SIZE / 4)
              asm.mov(:eax, -1)
              asm.stos(32, rep: true)
              asm.mov(X86.mem(nil, memory[CHANGED_FROM], size: 32), SIZE)
              asm.mov(X86.mem(nil, memory[NOT_WHOLE], size: 32), 1)
              asm.mov(:dx, memory[NAME])
              asm.mov(:ax, OPEN_FILE << 8)
              asm.int(DOS_CALL)
              asm.jb("rt_save_started")
              asm.mov(:bx, :ax)
              emit_whole_file_call(asm, READ_FILE)
              asm.jb("rt_save_start_shut")
              asm.cmp(:ax, SIZE) # how many bytes DOS read
              asm.jne("rt_save_start_shut")
              asm.mov(X86.mem(nil, memory[NOT_WHOLE], size: 32), 0)
              asm.label("rt_save_start_shut")
              asm.mov(:ah, SHUT_FILE)
              asm.int(DOS_CALL)
              asm.label("rt_save_started")
            end

            # DOS's question about a disk it cannot use answered "fail" (see A DISK THAT CANNOT BE WRITTEN). DOS
            # puts its own routine back when the program ends.
            def emit_critical_error_answer(asm)
              asm.xor(:ax, :ax)
              asm.mov(:es, :ax)
              asm.cli
              asm.mov_offset(:ax, "rt_save_critical_error")
              asm.mov(X86.mem(nil, CRITICAL_ERROR_VECTOR, seg: :es), :ax)
              asm.mov(X86.mem(nil, CRITICAL_ERROR_VECTOR + 2, seg: :es), :cs)
              asm.sti
              asm.jmp("rt_save_critical_error_set")
              asm.label("rt_save_critical_error")
              asm.mov(:al, FAIL)
              asm.iret
              asm.label("rt_save_critical_error_set")
            end

            # DOS's read or write of the whole 32K, between the file whose handle is in BX and the save's segment.
            def emit_whole_file_call(asm, call)
              asm.mov(:cx, SIZE)
              asm.xor(:dx, :dx)
              asm.push(:ds)
              asm.mov_segment(:ax, :save)
              asm.mov(:ds, :ax)
              asm.mov(:ah, call)
              asm.int(DOS_CALL)
              asm.pop(:ds)
            end

            # rt_save_inside_or_stop: returns when the ECX bytes from EAX are inside save memory, and stops
            # the game with the fault in BX when they are not. A count below nought is no bytes, as the
            # interpreter has it. Changes EDX.
            def emit_inside_or_stop(asm, memory)
              fault = memory[Frame::FAULT]
              asm.label("rt_save_inside_or_stop")
              asm.test(:eax, :eax)
              asm.js("rt_save_outside")
              asm.mov(:edx, :eax)
              asm.add(:edx, :ecx)
              asm.jo("rt_save_outside")
              asm.cmp(:edx, SIZE)
              asm.jg("rt_save_outside")
              asm.ret
              asm.label("rt_save_outside")
              asm.movzx(:ebx, :bx)
              asm.mov(X86.mem(nil, fault, size: 32), :ebx)
              asm.mov(X86.mem(nil, fault + Frame::FAULT_FIRST, size: 32), :eax)
              asm.mov(X86.mem(nil, fault + Frame::FAULT_SECOND, size: 32), SIZE)
              asm.jmp("rt_fault")
            end

            # rt_save_read: EAX = the ECX bytes (1, 2 or 4) at EAX, lowest first: a byte and a half as they
            # are, a word as the signed number it is.
            def emit_read(asm)
              asm.label("rt_save_read")
              asm.mov(:bx, Frame::SAVE_READ_OUTSIDE)
              asm.call("rt_save_inside_or_stop")
              asm.push(:es)
              asm.mov_segment(:dx, :save)
              asm.mov(:es, :dx)
              asm.mov(:bx, :ax)
              asm.cmp(:cl, 1)
              asm.jne("rt_save_read_not_byte")
              asm.movzx(:eax, X86.mem(:bx, 0, seg: :es, size: 8))
              asm.jmp("rt_save_read_done")
              asm.label("rt_save_read_not_byte")
              asm.cmp(:cl, 2)
              asm.jne("rt_save_read_word")
              asm.movzx(:eax, X86.mem(:bx, 0, seg: :es, size: 16))
              asm.jmp("rt_save_read_done")
              asm.label("rt_save_read_word")
              asm.mov(:eax, X86.mem(:bx, 0, seg: :es, size: 32))
              asm.label("rt_save_read_done")
              asm.pop(:es)
              asm.ret
            end

            # rt_save_write: the low EDX bytes (1, 2 or 4) of ECX at EAX, lowest first, in memory, and marked
            # as changed for the disk (rt_save_flush).
            def emit_write(asm, memory)
              from = X86.mem(nil, memory[CHANGED_FROM], size: 16)
              to = X86.mem(nil, memory[CHANGED_TO], size: 16)
              asm.label("rt_save_write")
              asm.push(:ecx)
              asm.mov(:ecx, :edx)
              asm.mov(:bx, Frame::SAVE_WRITE_OUTSIDE)
              asm.call("rt_save_inside_or_stop")
              asm.pop(:edx)
              asm.push(:es)
              asm.mov_segment(:bx, :save)
              asm.mov(:es, :bx)
              asm.mov(:bx, :ax)
              asm.cmp(:cl, 1)
              asm.jne("rt_save_write_not_byte")
              asm.mov(X86.mem(:bx, 0, seg: :es), :dl)
              asm.jmp("rt_save_write_kept")
              asm.label("rt_save_write_not_byte")
              asm.cmp(:cl, 2)
              asm.jne("rt_save_write_word")
              asm.mov(X86.mem(:bx, 0, seg: :es), :dx)
              asm.jmp("rt_save_write_kept")
              asm.label("rt_save_write_word")
              asm.mov(X86.mem(:bx, 0, seg: :es), :edx)
              asm.label("rt_save_write_kept")
              asm.pop(:es)
              asm.cmp(:ax, from)
              asm.jae("rt_save_write_from_kept")
              asm.mov(from, :ax)
              asm.label("rt_save_write_from_kept")
              asm.add(:ax, :cx)
              asm.cmp(:ax, to)
              asm.jbe("rt_save_write_to_kept")
              asm.mov(to, :ax)
              asm.label("rt_save_write_to_kept")
              asm.ret
            end

            # rt_save_flush: the bytes changed since the last one written to the file, in one write; or the
            # whole 32K where the file is not there or not whole. Nothing is done where nothing changed.
            # Changes AX, BX, CX and DX.
            def emit_flush(asm, memory)
              from = X86.mem(nil, memory[CHANGED_FROM], size: 16)
              to = X86.mem(nil, memory[CHANGED_TO], size: 16)
              not_whole = X86.mem(nil, memory[NOT_WHOLE], size: 16)
              asm.label("rt_save_flush")
              asm.cmp(to, 0)
              asm.je("rt_save_flushed")
              asm.cmp(not_whole, 0)
              asm.jne("rt_save_flush_whole")
              asm.mov(:dx, memory[NAME])
              asm.mov(:ax, (OPEN_FILE << 8) | OPENED_TO_WRITE)
              asm.int(DOS_CALL)
              asm.jb("rt_save_flush_whole")
              asm.mov(:bx, :ax)
              asm.mov(:ax, MOVE_IN_FILE << 8) # from the file's start, to the place in CX:DX
              asm.xor(:cx, :cx)
              asm.mov(:dx, from)
              asm.int(DOS_CALL)
              asm.mov(:cx, to)
              asm.sub(:cx, from)
              asm.mov(:dx, from)
              asm.push(:ds)
              asm.mov_segment(:ax, :save)
              asm.mov(:ds, :ax)
              asm.mov(:ah, WRITE_FILE)
              asm.int(DOS_CALL)
              asm.pop(:ds)
              asm.jmp("rt_save_flush_shut")
              asm.label("rt_save_flush_whole")
              asm.mov(not_whole, 1)
              asm.mov(:ah, MAKE_FILE)
              asm.xor(:cx, :cx) # a plain file: not hidden, not read-only
              asm.mov(:dx, memory[NAME])
              asm.int(DOS_CALL)
              asm.jb("rt_save_flush_clean") # a disk that cannot be written: the save stays in memory
              asm.mov(:bx, :ax)
              emit_whole_file_call(asm, WRITE_FILE)
              asm.jb("rt_save_flush_shut")
              asm.cmp(:ax, SIZE) # how many bytes DOS wrote: fewer on a full disk
              asm.jne("rt_save_flush_shut")
              asm.mov(not_whole, 0)
              asm.label("rt_save_flush_shut")
              asm.mov(:ah, SHUT_FILE)
              asm.int(DOS_CALL)
              asm.label("rt_save_flush_clean")
              asm.mov(from, SIZE)
              asm.mov(to, 0)
              asm.label("rt_save_flushed")
              asm.ret
            end

            # rt_save_sum: EAX = SaveLayout.checksum of the ECX bytes from EAX: the bytes' total in DX and the
            # totals' total in SI, each kept to sixteen bits, the second in the top half.
            def emit_sum(asm)
              asm.label("rt_save_sum")
              asm.mov(:bx, Frame::SAVE_READ_OUTSIDE)
              asm.call("rt_save_inside_or_stop")
              asm.push(:es)
              asm.mov_segment(:dx, :save)
              asm.mov(:es, :dx)
              asm.mov(:bx, :ax)
              asm.xor(:dx, :dx)
              asm.xor(:si, :si)
              asm.test(:ecx, :ecx)
              asm.jle("rt_save_sum_done")
              asm.label("rt_save_sum_byte")
              asm.xor(:ah, :ah)
              asm.mov(:al, X86.mem(:bx, 0, seg: :es))
              asm.add(:dx, :ax)
              asm.add(:si, :dx)
              asm.inc(:bx)
              asm.dec(:ecx)
              asm.jne("rt_save_sum_byte")
              asm.label("rt_save_sum_done")
              asm.movzx(:eax, :si)
              asm.shl(:eax, 16)
              asm.mov(:ax, :dx)
              asm.pop(:es)
              asm.ret
            end
          end
        end
      end
    end
  end
end
