# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A LIST AS THE COLOR AND THE SUPER NINTENDO KEEP IT: a header saying how many slots it has, where
    # the oldest item is and how many items it holds, and the slots after that. Their runtimes lay it
    # out alike, each naming the places in a Lists module of its own, which +list_layout+ hands over.
    #
    # A pool's list kept in its layout's area (+slot+, an IR::Backends::PoolLayout::SlotPlace counted
    # from the end of the list's header) keeps its header where the list is and its items there, each
    # at the pool's stride and kept multiplied by its scale; nothing takes such a list's items from the
    # front, so its oldest is in slot nought.
    module RuntimeLists
      private def kept_list_items(place, slot = nil)
        address, _capacity, width, = place
        layout = list_layout
        capacity = little_number(address + layout::CAPACITY)
        front = little_number(address + layout::FRONT)
        Array.new(little_number(address + layout::LENGTH)) do |i|
          next little_slot(address + layout::HEADER + slot.at(i), slot.width) / slot.scale if slot

          little_slot(address + layout::HEADER + (((front + i) % capacity) * width), width)
        end
      end

      private def little_number(address) = mem8(address) | (mem8(address + 1) << 8)
    end
  end
end
