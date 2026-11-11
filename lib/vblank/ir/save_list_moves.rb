# frozen_string_literal: true

module VBlank
  module IR
    # A WHOLE LIST MOVED TO OR FROM SAVE MEMORY (Nodes::SaveLoadList, Nodes::SaveStoreList), WRITTEN
    # OUT AS THE LOOPS IT STANDS FOR: a save_read and a list_push for each item, or a list_get and
    # a save_write. This is what the step means, said once, so a backend with no routine of its own
    # for it lowers these and cannot mean anything else. The interpreter runs the step itself, and
    # a test holds the two to the same save memory and the same list.
    #
    # The loops count in the variable the step names (+index+), which the builder declared.
    module SaveListMoves
      KINDS = %i[save_load_list save_store_list].freeze
      WIDTH_BYTES = { byte: 1, half: 2, word: 4 }.freeze

      module_function

      # The statements +node+ stands for, new nodes each time. Each knows the step's own parent, so a
      # backend lowering one finds the routine and the program it is in, though the tree does not
      # hold it.
      def loops_for(node)
        loops = node.kind == :save_load_list ? load_loops(node) : [store_loop(node)]
        # The counter is a variable of the game's like any other, so where it is left is part of
        # what the step does: at nought, whatever the loops counted to.
        loops << Build.set(node.index, 0)
        loops.each do |loop|
          loop.parent = node.parent
          loop.default_source!(node.source)
        end
      end

      # Whether +program+ moves a list to or from save memory: a lowering with routines of its own
      # for the steps takes them in only then.
      def moved_in?(program) = program.walk.any? { |node| KINDS.include?(node.kind) }

      # The count a block routine for a load is handed: the step's count held to nought and its
      # most. The routine copies without looking, so the most must be no more than the list holds;
      # a lowering refuses a step whose most is more (#past_capacity_message).
      def load_count(node) = Build.clamped(node.count.copy, Build.int(0), Build.int(node.most))

      # The words for a load step whose most is more than its list holds (+capacity+), or nil.
      def past_capacity_message(node, capacity)
        return if node.most <= capacity

        "A load of the list #{node.name.inspect} from save memory can make it #{node.most} long, and it holds #{capacity}."
      end

      def load_loops(node)
        emptied = Build.repeat(Build.list_len(node.name), node.index, Build.list_drop(node.name, from: :back))
        filled = Build.repeat(load_count(node), node.index, Build.list_push(node.name, Build.save_read(slot_at(node), width: node.width)))
        [emptied, filled]
      end

      def store_loop(node)
        item = Build.list_get(node.name, Build.var_ref(node.index))
        Build.repeat(Build.list_len(node.name), node.index, Build.save_write(slot_at(node), item, width: node.width))
      end

      # Where the slot the loop is on sits in save memory.
      def slot_at(node)
        Build.binop(:+, node.at.copy, Build.binop(:*, Build.var_ref(node.index), Build.int(WIDTH_BYTES.fetch(node.width))))
      end
    end
  end
end
