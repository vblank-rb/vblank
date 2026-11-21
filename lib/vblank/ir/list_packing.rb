# frozen_string_literal: true

module VBlank
  module IR
    # A LIST'S ITEMS WRITTEN INTO A LIST OF BYTES (Nodes::ListPack), WRITTEN OUT AS THE LOOP IT
    # STANDS FOR: for each item, a list_set of each of its bytes, lowest first. This is what the
    # step means, written once, so a backend with no block copy of its own for it lowers this and
    # cannot mean anything else. The interpreter runs the step itself, and a test holds the two
    # to the same bytes.
    #
    # The loop counts in the variable the step names (+index+), which the builder declared.
    module ListPacking
      WIDTH_BYTES = { byte: 1, half: 2, word: 4 }.freeze

      module_function

      # The statements +node+ stands for, new nodes each time, each knowing the step's own parent
      # (see SaveListMoves.loops_for).
      def loops_for(node)
        bytes = WIDTH_BYTES.fetch(node.width)
        item = -> { Build.list_get(node.name, Build.var_ref(node.index)) }
        first = Build.binop(:+, node.at.copy, Build.binop(:*, Build.var_ref(node.index), Build.int(bytes)))
        # A byte list keeps the low bits of what it is handed, so the byte at +b+ is the item
        # shifted down by that many bytes, with nothing masked.
        sets = Array.new(bytes) do |b|
          byte = b.zero? ? item.call : Build.binop(:>>, item.call, Build.int(8 * b))
          Build.list_set(node.into, b.zero? ? first.copy : Build.binop(:+, first.copy, Build.int(b)), byte)
        end
        loops = [Build.repeat(Build.list_len(node.name), node.index, *sets), Build.set(node.index, 0)]
        loops.each do |loop|
          loop.parent = node.parent
          loop.default_source!(node.source)
        end
      end

      # The test of whether +node+'s whole run lands inside the list it writes into, as a value: 1
      # where it starts at slot nought or later and its last byte is below that list's length, else
      # 0. Where it holds, the loop writes every byte and stops nothing, so a copy of the run means
      # the same. The start is held against the length less the run's bytes, which no list is long
      # enough to take below nought by wrapping, where the start plus them could wrap.
      def fit_test(node)
        bytes = WIDTH_BYTES.fetch(node.width)
        room = Build.binop(:-, Build.list_len(node.into), Build.binop(:*, Build.list_len(node.name), Build.int(bytes)))
        Build.binop(:&, Build.binop(:>=, node.at.copy, Build.int(0)), Build.binop(:<=, node.at.copy, room))
      end

      # THE STEP WRITTEN OUT AS ITS LOOP, for a cartridge lowering with no copy of its own for it
      # (Backends::ListPackBlocks::OWN_WAYS names those that have one). Mixed into the lowering, which
      # gives statement(node).
      module Loops
        def emit_list_pack(node) = ListPacking.loops_for(node).each { |loop| statement(loop) }
      end
    end
  end
end
