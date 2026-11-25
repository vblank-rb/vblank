# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A list as the Color, the Super Nintendo, the Genesis and the PlayStation keep it: a header saying how many slots
    # it has, where the oldest item is and how many items it holds, and the slots after that. Their
    # runtimes lay it out alike, each naming the places in a Lists module of its own, which
    # +list_layout+ hands over, with how many bytes each number of the header takes (FIELD_BYTES).
    #
    # The Color's and the Super Nintendo's processors keep a number's low byte at the lower address.
    # The Genesis's 68000 keeps the high byte there (Motorola's M68000 Family Programmer's Reference
    # Manual, "Organization of Data in Memory"), so its reader says
    # +big_endian?+ and every number of the header and every slot is read high byte first.
    #
    # A pool's list kept in its layout's area (+slot+, an IR::Backends::PoolLayout::SlotPlace counted
    # from the end of the list's header) keeps its header where the list is and its items there, each
    # at the pool's stride and kept multiplied by its scale; nothing takes such a list's items from the
    # front, so its oldest is in slot nought.
    module RuntimeLists
      private def kept_list_items(place, slot = nil)
        address, _capacity, width, = place
        layout = list_layout
        field = layout::FIELD_BYTES
        capacity = kept_number(address + layout::CAPACITY, field)
        front = kept_number(address + layout::FRONT, field)
        Array.new(kept_number(address + layout::LENGTH, field)) do |i|
          next kept_slot(address + layout::HEADER + slot.at(i), slot.width) / slot.scale if slot

          kept_slot(address + layout::HEADER + (((front + i) % capacity) * width), width)
        end
      end

      # Whether the console keeps a number's high byte at the lower address.
      private def big_endian? = false

      # The +bytes+ bytes at +address+ as one number with no sign, in the console's byte order.
      private def kept_number(address, bytes)
        (0...bytes).sum { |i| mem8(address + i) << (8 * (big_endian? ? bytes - 1 - i : i)) }
      end

      # A slot of +bytes+ bytes, read back with its top bit as the sign, as the interpreter's is.
      private def kept_slot(address, bytes)
        raw = kept_number(address, bytes)
        top = 1 << ((bytes * 8) - 1)
        raw >= top ? raw - (top << 1) : raw
      end
    end
  end
end
