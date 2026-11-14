# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # A VARIABLE KEPT A BYTE OR TWO WIDE (IR::KeptWidths). Mixed into Lowering.
          #
          # The Color's processor works on a byte at a time, so a four-byte variable costs four
          # trips to memory each time it is read, tested or written. One the game declared narrow
          # is kept in the bytes it needs, and the work is that many bytes: reading a byte and
          # testing it is `ld a,[nn]` and `cp`, and writing one is `ld [nn],a`. Writing only those
          # bytes is the wrap every other console does with a shift, so that statement is left out.
          #
          # The low bytes are all a sum needs (WrittenNumbers#low_value). A place that needs the whole
          # number, such as a call into the runtime, gets it by #load_kept_variable, the top
          # byte's sign copied upward, which is why a narrow variable reads the same as any other.
          module KeptVariables
            private

            # How many bytes variable +name+ is kept in, or nil for the whole four.
            def kept_bytes(name)
              width = kept_width(name)
              KeptWidths::BYTES.fetch(width) if width
            end

            # The width variable +name+ is kept at: the one the game declared, or :byte for one
            # only ever holding a byte (GBC::ByteVariables), or nil for the whole number. One whose
            # place the lowering hands over is whole (Lowering#place_of): a declared one still
            # holds only its width's numbers, since the wrap after each write is in the program.
            def kept_width(name)
              return nil if @cache.facts.handed_over.include?(name)

              @program.kept_width_of(name) || (:byte if byte_variables.include?(name))
            end

            # Whether the program keeps a variable named +name+.
            def keeps_variable?(name) = @variables.key?(name)

            # Where variable +name+ is kept, for code reading or writing only the bytes it is kept
            # in (#kept_bytes), or all four of a whole one. Anything else asks Lowering#place_of.
            def kept_place_of(name)
              @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
            end

            def byte_variables = @byte_variables ||= @cache.facts.byte_variables.to_set

            def kept_variable_named(node)
              name = any_variable_named(node)
              name if name && kept_bytes(name)
            end

            # The variable +node+ names if at least +bytes+ of it can be read where it is kept.
            def variable_kept_at_least(node, bytes)
              name = any_variable_named(node)
              name if name && (kept_bytes(name) || 4) >= bytes
            end

            # BCDE = the number, its sign copied up from its top byte.
            def load_kept_variable(name)
              place = kept_place_of(name)
              if kept_bytes(name) == 1
                @asm.load(:a, [place])
                @asm.load(:e, :a)
                @asm.rla
                @asm.sbc_a(:a)
                @asm.load(:d, :a)
              else
                @asm.load(:hl, place)
                @asm.load(:a, [:hli])
                @asm.load(:e, :a)
                @asm.load(:a, [:hl])
                @asm.load(:d, :a)
                @asm.rla
                @asm.sbc_a(:a)
              end
              @asm.load(:c, :a)
              @asm.load(:b, :a)
            end

            # E (and D) into the variable's bytes.
            def store_kept_bytes(name)
              place = kept_place_of(name)
              @asm.load(:a, :e)
              @asm.load([place], :a)
              if kept_bytes(name) == 2
                @asm.load(:a, :d)
                @asm.load([place + 1], :a)
              end
              emit_sprites_changed(name) unless sprites_placed_from(name).empty?
            end

            # `x = ...`, of which only the bytes kept are worked out. The wrap after it is nothing here.
            def emit_set_kept(node)
              name = node.var
              bytes = kept_bytes(name)
              return if KeptWidths.wrap?(node, kept_width(name))

              number = folded(node.value)
              return emit_written_number_kept(name, number) if number

              return low_value(node.value, bytes).then { store(name) } if bytes == 2

              emit_low_byte_in_a(node.value)
              @asm.load([kept_place_of(name)], :a)
              emit_sprites_changed(name) unless sprites_placed_from(name).empty?
            end

            def emit_written_number_kept(name, number)
              place = kept_place_of(name)
              @asm.load(:a, number & 0xFF)
              @asm.load([place], :a)
              if kept_bytes(name) == 2
                @asm.load(:a, (number >> 8) & 0xFF)
                @asm.load([place + 1], :a)
              end
              emit_sprites_changed(name) unless sprites_placed_from(name).empty?
            end

            # Whether +number+ is one variable +name+ can hold.
            def fits_kept?(name, number)
              width = kept_width(name)
              number.between?(KeptWidths.lowest(width), KeptWidths.highest(width))
            end

            def number_fits_kept?(operand, number)
              name = kept_variable_named(operand)
              !name.nil? && fits_kept?(name, number)
            end

            # A narrow variable tested to equal (or not) a number it can hold: [the variable, the
            # number]. One it cannot hold is left to the whole comparison, which gives the answer.
            def equality_of_kept(condition)
              return nil unless binop?(condition, :==) || binop?(condition, :!=)

              left, right = condition.lhs, condition.rhs
              left, right = right, left if folded(left)
              number = folded(right)
              name = kept_variable_named(left)
              [name, number] if number && name && fits_kept?(name, number)
            end

            # The zero flag set when the variable's bytes are +number+'s.
            def compare_kept_with_number(name, number)
              place = kept_place_of(name)
              @asm.load(:a, [place])
              @asm.cp_a(number & 0xFF)
              return if kept_bytes(name) == 1

              done = fresh("compared")
              @asm.jump_relative(:nz, done)
              @asm.load(:a, [place + 1])
              @asm.cp_a((number >> 8) & 0xFF)
              @asm.label(done)
            end

            # The carry set when the variable is below +number+, with their signs: the top byte's
            # sign bit turned over on both, so the negative numbers come below the rest.
            def emit_carry_when_kept_below(name, number)
              place = kept_place_of(name)
              number &= 0xFFFF
              if kept_bytes(name) == 1
                @asm.load(:a, [place])
                @asm.xor_a(0x80)
                return @asm.cp_a((number & 0xFF) ^ 0x80)
              end

              @asm.load(:a, [place + 1])
              @asm.xor_a(0x80)
              @asm.load(:h, :a) # a load moves no flag, so the carry from the byte below is kept
              @asm.load(:a, [place])
              @asm.sub_a(number & 0xFF)
              @asm.load(:a, :h)
              @asm.sbc_a((number >> 8) ^ 0x80)
            end

            # Two variables kept at the same width tested to equal (or not) each other: [the one, the
            # other]. Nil for any other test.
            def equality_of_two_kept(condition)
              return nil unless binop?(condition, :==) || binop?(condition, :!=)

              left, right = kept_variable_named(condition.lhs), kept_variable_named(condition.rhs)
              [left, right] if left && right && kept_bytes(left) == kept_bytes(right)
            end

            # The zero flag set when the two variables' bytes are the same, leaving at the first
            # that differs.
            def compare_two_kept(one, other)
              first, second = kept_place_of(one), kept_place_of(other)
              done = fresh("compared")
              kept_bytes(one).times do |i|
                @asm.jump_relative(:nz, done) unless i.zero?
                @asm.load(:a, [second + i])
                @asm.load(:c, :a)
                @asm.load(:a, [first + i])
                @asm.cp_a(:c)
              end
              @asm.label(done)
            end

            # `negate!` on a variable kept narrow: nought take its bytes away, where they are. Only
            # the low bytes of a number decide the low bytes of its negative.
            def emit_negate_kept(name)
              @asm.load(:hl, kept_place_of(name))
              @asm.xor_a(:a)
              @asm.sub_a([:hl])
              @asm.load([:hl], :a)
              if kept_bytes(name) == 2
                @asm.inc(:hl)
                @asm.load(:a, 0) # a load moves no flag, so the borrow is kept
                @asm.sbc_a([:hl])
                @asm.load([:hl], :a)
              end
              emit_sprites_changed(name) unless sprites_placed_from(name).empty?
            end

            # An index a list can be read at in two bytes: a kept variable, or one with a number
            # written in the program added or taken away. That index cannot pass 16 bits by enough to
            # come round: the lowest it can be, as two bytes, is above every slot, so a number below
            # nought is past the end there too. False for a list too long, or a number too big, to say so.
            def kept_list_index?(index, capacity)
              return false unless capacity < LONGEST_KEPT_INDEX

              return !kept_variable_named(index).nil? unless index.is_a?(Node) && index.kind == :binop && %i[+ -].include?(index.op)

              left, right = index.lhs, index.rhs
              left, right = right, left if index.op == :+ && folded(left)
              number = folded(right)
              !number.nil? && number.abs < LONGEST_KEPT_INDEX && !kept_variable_named(left).nil?
            end

            # An index past this, or a list longer, could come back round into the list in two bytes.
            LONGEST_KEPT_INDEX = 0x4000

            # An index, in DE, in two bytes when it can be, and HL = its slot; a jump to
            # +out_of_range+ when it is outside the list. Otherwise as #emit_list_slot_address.
            # A two-byte index leaves no whole number in BCDE, so where that jump lands the index is
            # worked out again for the game to stop on. +fixed+ means the list is always as long as it
            # can be (Lowering#fixed_length_lists), so the index is held to its capacity.
            def emit_list_slot_of_index(index, place, capacity, width, out_of_range, fixed: false)
              length = (capacity if fixed)
              name = kept_variable_named(index)
              return emit_list_slot_of_byte(name, place, capacity, width, out_of_range, length: length) if name && kept_bytes(name) == 1 && capacity <= BYTE_INDEXED_CAPACITY
              if kept_list_index?(index, capacity)
                low_value(index, 2)
                return emit_list_slot_of_de(place, width, out_of_range, length: length)
              end

              value(index)
              emit_list_slot_address(place, width, out_of_range, length: length)
            end

            # Whether +operand+ is an item of a list kept with its first item in its first slot, so
            # its lowest byte can be read where it is (#emit_item_low_byte_in_a).
            def list_item_in_place?(operand)
              operand.is_a?(Node) && operand.kind == :list_get && !front_dropped_lists.include?(operand.name)
            end

            # A = the lowest byte of the item +item+ reads, from its slot, lowest byte first, with no
            # whole number made of it: a pool's link read into a variable kept in a byte. An index
            # out of range stops the game, as reading the item would.
            def emit_item_low_byte_in_a(item)
              slot = fixed_slot(item)
              return @asm.load(:a, [slot]) if slot

              place, capacity, width = list_placed(item)
              out_of_range = fresh("list_index_out_of_range")
              read = fresh("list_item_read")
              emit_list_slot_of_index(item.index, place, capacity, width, out_of_range, fixed: fixed_length_lists.include?(item.name))
              @asm.load(:a, [:hl])
              @asm.jump(read)
              @asm.label(out_of_range)
              value(item.index) if kept_list_index?(item.index, capacity)
              list_get_through_routine(place)
              @asm.load(:a, :e)
              @asm.label(read)
            end

            # A list this long or shorter is indexed by a variable kept in a byte with one compare.
            BYTE_INDEXED_CAPACITY = 0x80

            # HL = the slot variable +name+, kept in one byte, names; a jump to +out_of_range+ when it
            # is outside the list. The byte read as a number from 0 to 255 is the index itself when
            # it is at or above nought, and 128 or more when it is below: past the end of a list no
            # longer than BYTE_INDEXED_CAPACITY either way, so one compare with the length (whose
            # high byte is nought) checks both ends. Where the jump lands the index is worked out
            # again, as for any kept index (#kept_list_index?).
            def emit_list_slot_of_byte(name, place, capacity, width, out_of_range, length: nil)
              @asm.load(:a, [kept_place_of(name)])
              if length
                @asm.cp_a(length)
              else
                @asm.load(:hl, place + Runtime::Lists::LENGTH)
                @asm.cp_a([:hl])
              end
              @asm.jump(:nc, out_of_range)
              @asm.load(:l, :a)
              @asm.load(:h, 0)
              (width / 2).times { @asm.add_hl(:hl) } # × the slot's width: 1, 2 or 4
              @asm.load(:de, place + Runtime::Lists::HEADER)
              @asm.add_hl(:de)
            end

            # An ordering of two variables kept at the same width: [the one, the other, and
            # whether it holds when the one is below the other], as WrittenNumbers does it.
            def ordering_of_two_kept(condition)
              return nil unless condition.is_a?(Node) && condition.kind == :binop && %i[< <= > >=].include?(condition.op)

              left, right = kept_variable_named(condition.lhs), kept_variable_named(condition.rhs)
              return nil unless left && right && kept_bytes(left) == kept_bytes(right)

              case condition.op
              when :< then [left, right, true]
              when :>= then [left, right, false]
              when :> then [right, left, true]
              else [right, left, false]
              end
            end

            # The carry set when variable +one+ is below variable +other+, with their signs.
            def emit_carry_when_kept_below_kept(one, other)
              first, second = kept_place_of(one), kept_place_of(other)
              if kept_bytes(one) == 2
                @asm.load(:a, [second + 1])
                @asm.xor_a(0x80)
                @asm.load(:c, :a)
                @asm.load(:a, [first + 1])
                @asm.xor_a(0x80)
                @asm.load(:b, :a)
                @asm.load(:hl, second)
                @asm.load(:a, [first])
                @asm.sub_a([:hl])
                @asm.load(:a, :b)
                return @asm.sbc_a(:c)
              end

              @asm.load(:a, [second])
              @asm.xor_a(0x80)
              @asm.load(:c, :a)
              @asm.load(:a, [first])
              @asm.xor_a(0x80)
              @asm.cp_a(:c)
            end
          end
        end
      end
    end
  end
end
