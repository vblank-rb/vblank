# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # HOW A CONSOLE KEEPS A POOL IN MEMORY, one layout per pool, chosen as the game is built.
      #
      # A pool reaches the tree as plain lists, variables and loops (DSL::Pool), and the interpreter
      # runs that tree: one list for each field and for the pool's own bookkeeping, a repeat for each
      # walk. Every lowering keeps it so today, a list in memory for each list of the tree. That is
      # the :lists layout, which every console has. A console's own games keep their things the way
      # its processor reaches memory cheaply: on the Super Nintendo, a record for each thing or tables
      # side by side, either read with one index register held on the thing for every field; on the
      # Color, a record with HL pointed at it; on the Genesis, a record with an address register on it
      # (https://snes.nesdev.org/wiki/65C816, https://gbdev.io/pandocs/, https://plutiedev.com/).
      # A layout of a console's own is an adapter of this interface, chosen per pool,
      # so adding one is one new adapter and no lowering's code changes for a pool it does not keep.
      #
      # WHAT A LAYOUT SAYS (an adapter):
      #
      #   name                      :lists, :tables or :records (Console::Description#pool_layouts)
      #   fits?(shape, steps)       whether it can keep this pool (IR::PoolShape), given every kind of
      #                             step the program takes on the pool's lists (#steps_on): a layout
      #                             that cannot keep one says so, and the pool keeps :lists, so a game
      #                             that builds today always builds
      #   place(shape)              where each of the pool's slot lists is (a Placement)
      #
      # WHAT A PLACEMENT SAYS, in bytes and numbers, never one processor's registers: the pool's
      # areas of memory, and for each slot list where slot s of it is (SlotPlace#at), how wide its
      # value is, and the number it is kept multiplied by. Each lowering turns that into its own
      # instructions: an index register set once to the slot times the stride where every list
      # shares one (Placement#shared_stride), a base register and an offset, or a statement of the
      # computer builds. The values a checked run and the game read keep the tree's meaning: a value
      # kept multiplied is divided where it is read as a number, and a walk stepped its own way leaves
      # each of its variables (#walk_results) with the number the tree gives it, as the walk ends and
      # before any frame boundary in its body. A lowering's headless run reads a pool's lists back
      # through the same Placement.
      module PoolLayout
        # Where slot s of one list is: +offset+ + s * +stride+ bytes into its +area+, +width+ bytes
        # of value, kept multiplied by +scale+ (1 for a number as the tree holds it).
        SlotPlace = Data.define(:area, :offset, :stride, :width, :scale) do
          def at(slot) = offset + (slot * stride)
        end

        # A pool laid out: the +layout+ that placed it, its +areas+ (name => bytes) and its slot
        # lists' places (+slots+, list => SlotPlace).
        Placement = Data.define(:layout, :areas, :slots) do
          def place_of(list) = slots.fetch(list)

          # The stride every slot list shares, so one slot number times it reaches any field of the
          # thing; nil where they differ.
          def shared_stride
            strides = slots.values.map(&:stride).uniq
            strides.first if strides.one?
          end
        end

        # TODAY'S LAYOUT, every console's: each slot list in an area of its own, a slot as wide as the
        # list, kept as the tree holds it. A lowering keeping a pool so builds it as it always has.
        class Lists
          def name = :lists
          def fits?(_shape, _steps) = true

          def place(shape)
            places = shape.slot_lists.to_h do |list, width|
              bytes = Build::ELEMENT_BYTES.fetch(width)
              [list, SlotPlace.new(area: list, offset: 0, stride: bytes, width: bytes, scale: 1)]
            end
            Placement.new(layout: name, areas: places.to_h { |list, place| [list, shape.capacity * place.stride] },
                          slots: places)
          end
        end

        # Every layout there is an adapter for, by name.
        ADAPTERS = Ractor.make_shareable({ lists: Lists.new })

        # EACH CONSOLE'S LAYOUTS BEYOND :lists, with why its build keeps a pool that way: the measured
        # reason, as ControlFlow::OWN_WAYS gives its lowerings' own ways. test_pool_layout.rb holds
        # each console's Console::Description#pool_layouts to this list, both ways.
        OWN_LAYOUTS = Ractor.make_shareable({})

        module_function

        # The layout +shape+ is kept in on +console+ (a Console::Description), given +steps+, the
        # kinds of step the program takes on its lists (#steps_on): the one the game named, which the
        # builder has already refused where the console lacks it, else the first of the console's
        # layouts that has an adapter and fits; :lists when none does.
        def chosen(shape, console, steps)
          names = [shape.layout, *console.pool_layouts].compact.uniq
          names.each do |name|
            adapter = ADAPTERS[name]
            return adapter if adapter&.fits?(shape, steps)
          end
          ADAPTERS.fetch(:lists)
        end

        # The kinds of step +program+ takes that name one of +shape+'s slot lists, as #chosen and an
        # adapter's #fits? read them: a layout that cannot fill, copy, sort or save a list kept its
        # way says so there.
        def steps_on(program, shape)
          lists = shape.slot_lists.keys
          program.walk.filter_map { |node| node.kind if node.respond_to?(:name) && lists.include?(node.name) }.uniq
        end

        # The variables a walk (IR::WalkShape) leaves its numbers in, which a layout stepping the walk
        # its own way writes back as the walk ends and before any frame boundary in its body: the
        # thing it is on and the one it goes to next. The repeat's own index is its count of turns.
        def walk_results(walk) = [walk.at, walk.ahead]
      end
    end
  end
end
