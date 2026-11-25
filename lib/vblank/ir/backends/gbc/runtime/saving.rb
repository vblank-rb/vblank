# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # Save memory: 32K of memory on the cartridge kept by a battery while the console is off,
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

            # One byte of rt_save_sum: the byte at BC added into the low sum, DE, and the low sum
            # into the high sum, HL. +label+ is where a byte with no carry out of E goes on.
            def emit_sum_byte(asm, label)
              asm.load(:a, [:bc])
              asm.inc(:bc)
              asm.add_a(:e)
              asm.load(:e, :a)
              asm.jump_relative(:nc, label)
              asm.inc(:d)
              asm.label(label)
              asm.add_hl(:de)
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
              # The loop over the bytes is the routine's whole cost, so it keeps every number it
              # works on in registers: the place in BC, the low sum in DE, the high sum in HL,
              # where one ADD HL,DE adds the low sum into it.
              # That leaves no pair for the bytes left, so the bytes are taken in runs that stay
              # inside one 256-byte page of the memory, and a run ends when the low byte of the
              # place reaches where it stops. The end of a bank is always the end of a page, so it
              # is only ever met between runs. Within a run the bytes go four to a turn, so the
              # test for the run's end is made once for four, after one at a time up to a
              # multiple of four. Eleven machine cycles a byte and a test (Pan Docs, "CPU
              # Instruction Set"), where testing the bank and keeping the high sum in the quick
              # memory took thirty-four.
              left = memory.args + 24 # 16 bits: the bytes left after the run under way
              stop = memory.args + 26 # the place's low byte where the run under way stops
              asm.label("rt_save_sum")
              asm.load_hl_sp(2)
              asm.load(:b, 8)
              asm.call("rt_take_args")
              asm.load(:de, arg2.call(0))
              asm.load(:hl, arg2.call(1))
              asm.load(:a, Frame::SAVE_READ_OUTSIDE)
              asm.call("rt_save_at")
              asm.load(:b, :h) # the place
              asm.load(:c, :l)
              asm.load(:hl, 0) # the high sum
              asm.load(:de, 0) # the low sum
              asm.load_high(:a, arg2.call(1) + 3)
              asm.bit(7, :a)
              asm.jump(:nz, "rt_save_sum_done") # a length below nought: no bytes
              # The length's low 16 bits: rt_save_at has held the place and the length inside
              # the 32K, so the high ones are nought.
              asm.load_high(:a, arg2.call(1))
              asm.load_high(left, :a)
              asm.load(:l, :a)
              asm.load_high(:a, arg2.call(1) + 1)
              asm.load_high(left + 1, :a)
              asm.or_a(:l)
              asm.load(:l, 0) # the high sum again, the flags kept
              asm.jump(:z, "rt_save_sum_done")
              # One run: up to the end of the page BC is in, or of the bytes left if sooner. Past
              # the end of a bank, the next one is put in view, as rt_save_next does for HL.
              asm.label("rt_save_sum_run")
              asm.load(:a, :b)
              asm.cp_a((h::SRAM + BANK_SIZE) >> 8)
              asm.jump_relative(:nz, "rt_save_sum_in_bank")
              asm.load(:b, h::SRAM >> 8)
              asm.load_high(:a, memory.args + 28)
              asm.inc(:a)
              asm.load_high(memory.args + 28, :a)
              emit_ram_bank(asm, memory)
              asm.label("rt_save_sum_in_bank")
              asm.load_high(:a, left + 1)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_save_sum_page")
              asm.load_high(:a, left)
              asm.add_a(:c) # where the bytes left end, when that is inside this page
              asm.jump_relative(:c, "rt_save_sum_page")
              asm.load_high(stop, :a)
              asm.xor_a(:a)
              asm.load_high(left, :a) # none left after this run
              asm.jump_relative("rt_save_sum_ones")
              # The rest of the page: 256 - C bytes taken off what is left, which is
              # left - 256 + C, and the run stops where C comes round to nought.
              asm.label("rt_save_sum_page")
              asm.load_high(:a, left)
              asm.add_a(:c)
              asm.load_high(left, :a)
              asm.load_high(:a, left + 1)
              asm.adc_a(0)
              asm.dec(:a)
              asm.load_high(left + 1, :a)
              asm.xor_a(:a)
              asm.load_high(stop, :a)
              # A byte at a time until what is left of the run is a multiple of four.
              asm.label("rt_save_sum_ones")
              asm.load_high(:a, stop)
              asm.sub_a(:c)
              asm.and_a(3)
              asm.jump_relative(:z, "rt_save_sum_byte")
              emit_sum_byte(asm, "rt_save_sum_one")
              asm.load_high(:a, stop) # a run of fewer than four ends here
              asm.cp_a(:c)
              asm.jump_relative(:z, "rt_save_sum_next")
              asm.jump_relative("rt_save_sum_ones")
              # A run is never empty, so a run of a whole page, which starts and stops where C
              # is nought, is not taken for one.
              asm.label("rt_save_sum_byte")
              4.times { |i| emit_sum_byte(asm, "rt_save_sum_four_#{i}") }
              asm.load_high(:a, stop)
              asm.cp_a(:c)
              asm.jump_relative(:nz, "rt_save_sum_byte")
              asm.label("rt_save_sum_next")
              asm.load_high(:a, left)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_save_sum_run")
              asm.load_high(:a, left + 1)
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_save_sum_run")
              asm.label("rt_save_sum_done")
              asm.load(:a, :e)
              asm.load_high(memory.args + 24, :a)
              asm.load(:a, :d)
              asm.load_high(memory.args + 25, :a)
              asm.load(:a, :l)
              asm.load_high(memory.args + 26, :a)
              asm.load(:a, :h)
              asm.load_high(memory.args + 27, :a)
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
              #
              # A place and a count that both fit in 16 bits, which is every place in the 32K and
              # every count a save asks for, are checked with one 16-bit sum; only a number with
              # its high bytes set (below nought, or far past the end) takes the 32-bit check.
              asm.label("rt_save_at")
              asm.push(:af)
              asm.push(:de)
              asm.push(:hl)
              asm.inc(:de)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.load(:b, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.or_a(:b)
              asm.load(:b, :a)
              asm.inc(:hl)
              asm.inc(:hl)
              asm.load(:a, [:hli])
              asm.or_a(:b)
              asm.or_a([:hl])
              asm.pop(:hl)
              asm.pop(:de)
              asm.push(:de)
              asm.jump_relative(:nz, "rt_save_at_wide")
              asm.load(:a, [:hli]) # BC = the count's low 16 bits
              asm.load(:c, :a)
              asm.load(:b, [:hl])
              asm.load(:a, [:de]) # + the place's: where it ends
              asm.add_a(:c)
              asm.load(:c, :a)
              asm.inc(:de)
              asm.load(:a, [:de])
              asm.adc_a(:b)
              asm.jump_relative(:c, "rt_save_outside")
              asm.cp_a(SIZE >> 8)
              asm.jump_relative(:c, "rt_save_inside")
              asm.jump_relative(:nz, "rt_save_outside")
              asm.load(:a, :c)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_save_inside")
              asm.jump_relative("rt_save_outside")
              asm.label("rt_save_at_wide")
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
