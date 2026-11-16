# frozen_string_literal: true

module VBlank
  module IR
    # WHAT A POOL IS, FOR A LOWERING THAT KEEPS ONE ITS OWN WAY. A pool reaches the tree as plain
    # lists, variables and loops (DSL::Pool): one list for each field and for its own bookkeeping,
    # variables for its chain's two ends and its count, and a repeat for each walk. The interpreter
    # and every lowering that keeps a pool as those lists run that tree and never read this. A
    # lowering that lays a pool out another way (Backends::PoolLayout) reads it to know which lists
    # and variables are one pool's, and what each holds.
    #
    # +fields+ are the game's fields, each with its list and the width the game declared (:byte,
    # :half or :word; never narrower than declared). +slot_lists+ are every list of the pool indexed
    # by a slot, the fields' first, then its own: whether a thing is live, its links to the things
    # spawned after and before it, and its pose lists. +stack_lists+ are its lists of slots that grow
    # and shrink (the free slots, the things removed during a walk). +vars+ names its variables by
    # what they hold. +layout+ is the layout the game asked for (`pool :enemy, ..., layout: :tables`),
    # or nil where the lowering chooses. +link_lists+ are the slot lists that hold a slot or NONE:
    # the links to the thing spawned after and the one before, which a layout may keep as the slot
    # times its stride (Backends::PoolLayout::SlotPlace#scale).
    PoolShape = Data.define(:name, :capacity, :fields, :slot_lists, :stack_lists, :vars, :layout, :link_lists) do
      # The width of +list+, one of the pool's slot lists, or nil for a list that is not one.
      def width_of(list) = slot_lists[list]
    end

    # One field of a pool: its name, the list it is kept in, and the width the game declared.
    PoolField = Data.define(:name, :list, :width)

    # WHAT A WALK OF A POOL IS, on the repeat the walk makes (Nodes::Repeat#pool_walk). The walk's
    # first +step_statements+ statements step it: the thing it is on (+at+) is the one it was going
    # to next (+ahead+), and +ahead+ becomes the thing after it along +links+, or NONE once +at+ is
    # +last+. The repeat's index counts its turns. Each names a variable or list of today's tree,
    # which keeps its meaning: a lowering stepping the walk its own way leaves each with the number
    # the tree would have given it wherever the game or a checked run can read it.
    WalkShape = Data.define(:pool, :at, :ahead, :last, :links, :step_statements)
  end
end
