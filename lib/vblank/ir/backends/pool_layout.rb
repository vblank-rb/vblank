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

        # THE STEPS A LAYOUT OF ITS OWN KEEPS A POOL'S LIST THROUGH: making it full, reading and
        # writing a slot, and asking its length. The runtime's other list routines (filling part of
        # it, copying, sorting, saving) walk a list's slots one after another from its header, so a
        # pool whose lists any of those reach is kept as :lists.
        STRIDED_STEPS = %i[list_new list_get list_set list_len].freeze

        # The most bytes a pool kept another way than :lists may take, so its slots stay reachable
        # with a 16-bit index: a pool bigger keeps :lists.
        MOST_STRIDED_BYTES = 0x8000

        # Whether +shape+ can be kept at one stride for every slot list, given +steps+.
        def self.strided_fits?(shape, steps, bytes)
          (steps - STRIDED_STEPS).empty? && bytes <= MOST_STRIDED_BYTES
        end

        # TABLES SIDE BY SIDE: each slot list in an area of its own, as :lists, but every slot as wide
        # as the pool's widest list, so one index, the slot number times that stride, reaches the same
        # thing's slot in any of them. Each value keeps its own width at the front of its slot. A pool
        # whose lists are all one width is already kept so, and stays :lists.
        class Tables
          def name = :tables

          def fits?(shape, steps)
            widths = shape.slot_lists.values.map { |width| Build::ELEMENT_BYTES.fetch(width) }
            widths.uniq.length > 1 && PoolLayout.strided_fits?(shape, steps, widths.length * shape.capacity * widths.max)
          end

          def place(shape)
            stride = shape.slot_lists.values.map { |width| Build::ELEMENT_BYTES.fetch(width) }.max
            places = shape.slot_lists.to_h do |list, width|
              [list, SlotPlace.new(area: list, offset: 0, stride: stride, width: Build::ELEMENT_BYTES.fetch(width), scale: 1)]
            end
            Placement.new(layout: name, areas: places.keys.to_h { |list| [list, shape.capacity * stride] }, slots: places)
          end
        end

        # A RECORD FOR EACH THING: every slot list of the pool in one area, the thing's values side by
        # side in a record, widest first so each sits at an offset its width divides, the record
        # rounded up to a power of two so the slot number times it is a few doublings. One index
        # reaches every value of one thing.
        class Records
          def name = :records

          def fits?(shape, steps)
            PoolLayout.strided_fits?(shape, steps, shape.capacity * record_bytes(shape))
          end

          def place(shape)
            stride = record_bytes(shape)
            area = :"#{shape.name} records"
            offset = 0
            places = shape.slot_lists.sort_by { |list, width| [-Build::ELEMENT_BYTES.fetch(width), list.to_s] }.to_h do |list, width|
              bytes = Build::ELEMENT_BYTES.fetch(width)
              place = SlotPlace.new(area: area, offset: offset, stride: stride, width: bytes, scale: 1)
              offset += bytes
              [list, place]
            end
            Placement.new(layout: name, areas: { area => shape.capacity * stride }, slots: places)
          end

          def record_bytes(shape)
            bytes = shape.slot_lists.values.sum { |width| Build::ELEMENT_BYTES.fetch(width) }
            1 << (bytes - 1).bit_length
          end
        end

        # Every layout there is an adapter for, by name.
        ADAPTERS = Ractor.make_shareable({ lists: Lists.new, tables: Tables.new, records: Records.new })

        # EACH CONSOLE'S LAYOUTS BEYOND :lists, with why its build keeps a pool that way: the measured
        # reason, as ControlFlow::OWN_WAYS gives its lowerings' own ways. test_pool_layout.rb holds
        # each console's Console::Description#pool_layouts to this list, both ways.
        OWN_LAYOUTS = Ractor.make_shareable(
          {
            snes: {
              tables: "One X, the slot times the pool's widest slot, reaches every field of the thing a walk " \
                      "is on, and the walk is stepped in X (SNES::Lowering#emit_stepped_walk). Measured in bsnes, " \
                      "one more pair of things checked: 1010 master clocks as lists, 876 as tables (half " \
                      "words: 900, 758); the bullets test 7.77% of a frame, 7.25%.",
              records: "A record for each thing, as Super Bomberman keeps its objects: one X reaches every field, " \
                       "but the record's stride is the sum of the widths rounded up, more doublings to set X. " \
                       "Measured in bsnes, one more pair: 924 master clocks (half words 806); the bullets test 7.77%."
            }
          }
        )

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
          program.walk.filter_map do |node|
            node.kind if node.attrs.values.flatten.any? { |held| held.is_a?(Symbol) && lists.include?(held) }
          end.uniq
        end

        # The variables a walk (IR::WalkShape) leaves its numbers in, which a layout stepping the walk
        # its own way writes back as the walk ends and before any frame boundary in its body: the
        # thing it is on and the one it goes to next. The repeat's own index is its count of turns.
        def walk_results(walk) = [walk.at, walk.ahead]
      end
    end
  end
end
