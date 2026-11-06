# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # SAVE MEMORY: 32K of memory on the cartridge kept by a battery while the console is off,
          # which is what a Game Boy Color game saves in. The interpreter's save memory is the
          # Advance's battery-backed one, also 32K and also written a byte at a time
          # (IR::SaveLayout), so the same bytes land in the same places on both.
          #
          # The processor sees 8K of it at a time, at 0xA000, whichever of its four banks the
          # cartridge's memory bank controller was last told; and only while it is switched on,
          # which it is only for as long as one of these routines runs — a console switched off
          # with it on can write nonsense into it on the way down.
          #
          # rt_save_read(at, width) and rt_save_write(at, value, width) take one, two or four
          # bytes, lowest first; rt_save_sum(at, length) is SaveLayout.checksum's two 16-bit sums;
          # rt_save_erase does nothing, battery-backed memory needing no wiping before it is
          # written. A place outside the 32K stops the game, as it stops the interpreter.
          module Saving
            SIZE = 0x8000
            BANK_SIZE = 0x2000

            module_function

            # The save memory's bank A in view: through rt_ram_bank in a game that runs the
            # cartridge's motor from the same register, so the motor stays as it stands
            # (Runtime::Rumble); straight to the register otherwise.
            def emit_ram_bank(asm, memory)
              return asm.call("rt_ram_bank") if Rumble.any?(memory)

              asm.load([Console::GBCHardware::MBC_RAM_BANK], :a)
            end

            def emit(asm, memory)
              h = Console::GBCHardware
              arg2 = ->(i) { Calls.arg(memory, i, 2) }
              arg3 = ->(i) { Calls.arg(memory, i, 3) }

              asm.label("rt_save_read") # (at, width)
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:de, arg2.call(0))
              asm.load(:hl, arg2.call(1))
              asm.load(:a, Frame::SAVE_READ_OUTSIDE)
              asm.call("rt_save_at")
              asm.load_high(:a, arg2.call(1)) # the width, 1 to 4
              asm.load(:b, :a)
              asm.load(:de, memory.args + 24) # the bytes read, into the scratch past the numbers
              asm.push(:de)
              asm.xor_a(:a)
              4.times do |i|
                asm.load_high(memory.args + 24 + i, :a)
              end
              asm.pop(:de)
              asm.label("rt_save_read_byte")
              asm.call("rt_save_next")
              asm.load(:a, [:hli])
              asm.load([:de], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_save_read_byte")
              asm.call("rt_save_off")
              asm.load(:hl, memory.args + 24)
              asm.jump("rt_load32")

              asm.label("rt_save_write") # (at, value, width)
              asm.load_hl_sp(2)
              asm.load(:b, 12)
              asm.call("rt_take_args")
              asm.load(:de, arg3.call(0))
              asm.load(:hl, arg3.call(2))
              asm.load(:a, Frame::SAVE_WRITE_OUTSIDE)
              asm.call("rt_save_at")
              asm.load_high(:a, arg3.call(2))
              asm.load(:b, :a)
              asm.load(:de, arg3.call(1))
              asm.label("rt_save_write_byte")
              asm.call("rt_save_next")
              asm.load(:a, [:de])
              asm.load([:hli], :a)
              asm.inc(:de)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_save_write_byte")
              asm.jump("rt_save_off")

              # (at, length): low += byte, high += low, each 16 bits.
              #
              # The loop over the bytes is the routine's whole cost, so it keeps what it can in
              # registers, as a retail game's checksum loop does: the place in HL, the bytes left
              # in BC, the low sum in DE, and only the high sum in the quick memory, for want of a
              # fourth pair. The end of a bank is tested in line, and rt_save_next (which tests
              # it again) called only there. Four reads and writes of the quick memory a byte,
              # where keeping every number there took fourteen and a call.
              asm.label("rt_save_sum")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:de, arg2.call(0))
              asm.load(:hl, arg2.call(1))
              asm.load(:a, Frame::SAVE_READ_OUTSIDE)
              asm.call("rt_save_at")
              asm.xor_a(:a)
              asm.load_high(memory.args + 26, :a) # the high sum
              asm.load_high(memory.args + 27, :a)
              asm.load(:d, :a) # the low sum
              asm.load(:e, :a)
              asm.load_high(:a, arg2.call(1) + 3)
              asm.bit(7, :a)
              asm.jump_relative(:nz, "rt_save_sum_done") # a length below nought: no bytes
              # The length's low 16 bits: rt_save_at has held the place and the length inside
              # the 32K, so the high ones are nought.
              asm.load_high(:a, arg2.call(1))
              asm.load(:c, :a)
              asm.load_high(:a, arg2.call(1) + 1)
              asm.load(:b, :a)
              asm.or_a(:c)
              asm.jump_relative(:z, "rt_save_sum_done")
              asm.label("rt_save_sum_byte")
              asm.load(:a, :h)
              asm.cp_a((h::SRAM + BANK_SIZE) >> 8)
              asm.call(:z, "rt_save_next")
              asm.load(:a, [:hli])
              asm.add_a(:e)
              asm.load(:e, :a)
              asm.jump_relative(:nc, "rt_save_sum_low")
              asm.inc(:d)
              asm.label("rt_save_sum_low")
              asm.load_high(:a, memory.args + 26)
              asm.add_a(:e)
              asm.load_high(memory.args + 26, :a)
              asm.load_high(:a, memory.args + 27)
              asm.adc_a(:d)
              asm.load_high(memory.args + 27, :a)
              asm.dec(:bc)
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.jump_relative(:nz, "rt_save_sum_byte")
              asm.label("rt_save_sum_done")
              asm.load(:a, :e)
              asm.load_high(memory.args + 24, :a)
              asm.load(:a, :d)
              asm.load_high(memory.args + 25, :a)
              asm.call("rt_save_off")
              asm.load(:hl, memory.args + 24)
              asm.jump("rt_load32")

              # Battery-backed memory needs no wiping.
              asm.label("rt_save_erase")
              asm.ret

              # The place at DE and the count at HL (both 32-bit numbers): inside the save memory,
              # or the game stopped with what went wrong (A) — the place and the size as the
              # fault's two numbers. Inside, the memory is switched on, the place's bank is in view,
              # and HL is where the place is seen.
              asm.label("rt_save_at")
              asm.push(:af)
              asm.push(:de)
              asm.push(:hl)
              asm.load(:h, :d)
              asm.load(:l, :e)
              asm.call("rt_load32")
              asm.pop(:hl)
              asm.bit(7, :b)
              asm.jump_relative(:nz, "rt_save_outside")
              asm.call("rt_add32") # where it ends: no further than the end of the memory
              asm.load(:a, :b)
              asm.or_a(:c)
              asm.jump_relative(:nz, "rt_save_outside")
              asm.load(:a, :d)
              asm.cp_a(SIZE >> 8)
              asm.jump_relative(:c, "rt_save_inside")
              asm.jump_relative(:nz, "rt_save_outside")
              asm.load(:a, :e)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_save_outside")
              asm.label("rt_save_inside")
              asm.pop(:de)
              asm.pop(:af)
              asm.load(:a, [:de])
              asm.load(:l, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.load(:h, :a)
              asm.load(:a, h::MBC_RAM_ON)
              asm.load([h::MBC_RAM_ENABLE], :a)
              asm.load(:a, :h) # the bank: the place ÷ 8K
              asm.swap(:a)
              asm.srl(:a)
              asm.and_a(3)
              asm.load_high(memory.args + 28, :a)
              emit_ram_bank(asm, memory)
              asm.load(:a, :h)
              asm.and_a((BANK_SIZE - 1) >> 8)
              asm.or_a(h::SRAM >> 8)
              asm.load(:h, :a)
              asm.ret
              asm.label("rt_save_outside")
              asm.pop(:hl) # the place's address
              asm.load(:de, memory[Frame::FAULT] + 3)
              asm.load(:b, 4)
              asm.call("rt_copy_b")
              asm.load(:hl, memory[Frame::FAULT] + 7)
              [SIZE & 0xFF, SIZE >> 8, 0, 0].each do |byte|
                asm.load([:hl], byte)
                asm.inc(:hl)
              end
              asm.pop(:af)
              asm.jump("rt_fault")

              # Before each byte: past the end of a bank, the next one in view.
              asm.label("rt_save_next")
              asm.load(:a, :h)
              asm.cp_a((h::SRAM + BANK_SIZE) >> 8)
              asm.ret(:nz)
              asm.load(:h, h::SRAM >> 8)
              asm.load_high(:a, memory.args + 28)
              asm.inc(:a)
              asm.load_high(memory.args + 28, :a)
              emit_ram_bank(asm, memory)
              asm.ret

              # The memory switched off again.
              asm.label("rt_save_off")
              asm.xor_a(:a)
              asm.load([h::MBC_RAM_ENABLE], :a)
              asm.ret
            end
          end
        end
      end
    end
  end
end
