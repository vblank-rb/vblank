# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A LIST AS THE COLOR AND THE SUPER NINTENDO KEEP IT: a header saying how many slots it has, where
    # the oldest item is and how many items it holds, and the slots after that. Their runtimes lay it
    # out alike, each naming the places in a Lists module of its own, which +list_layout+ hands over.
    module RuntimeLists
      private def kept_list_items(place)
        address, _capacity, width, = place
        layout = list_layout
        capacity = little_number(address + layout::CAPACITY)
        front = little_number(address + layout::FRONT)
        Array.new(little_number(address + layout::LENGTH)) do |i|
          little_slot(address + layout::HEADER + (((front + i) % capacity) * width), width)
        end
      end

      private def little_number(address) = mem8(address) | (mem8(address + 1) << 8)
    end
  end
end
