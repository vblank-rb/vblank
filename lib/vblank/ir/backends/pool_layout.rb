# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # How a console keeps a pool in memory, one layout per pool, chosen as the game is built.
      #
      # A pool reaches the tree as plain lists, variables and loops (DSL::Pool), and the interpreter
      # runs that tree: one list for each field and for the pool's own bookkeeping, a repeat for each
      # walk. Every lowering keeps it so today, a list in memory for each list of the tree. That is
      # the :lists layout, which every console has. A console's own games keep their things the way
      # its processor reaches memory cheaply: on the Super Nintendo, a record for each thing or tables
      # side by side, either read with one index register held on the thing for every field; on the
      # Color, a record with HL pointed at it (https://snes.nesdev.org/wiki/65C816,
      # https://gbdev.io/pandocs/); on the Genesis, an address register on the thing and each field at
      # a distance written in the instruction, the d16(An) mode (Motorola's M68000 Programmer's
      # Reference Manual).
      # A layout of a console's own is an adapter of this interface, chosen per pool,
      # so adding one is one new adapter and no lowering's code changes for a pool it does not keep.
      #
      # What a layout says (an adapter):
      #
      #   name                      :lists, :tables or :records (Console::Description#pool_layouts)
      #   fits?(shape, steps)       whether it can keep this pool (IR::PoolShape), given every kind of
      #                             step the program takes on the pool's lists (#steps_on): a layout
      #                             that cannot keep one says so, and the pool keeps :lists, so a game
      #                             that builds today always builds
      #   place(shape)              where each of the pool's slot lists is (a Placement)
      #
      # What a placement says, in bytes and numbers, never one processor's registers: the pool's
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

        # Today's layout, every console's: each slot list in an area of its own, a slot as wide as the
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

        # The steps a layout of its own keeps a pool's list through: making it full, reading and
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

        # The bytes one slot of +list+ TAKES in a layout at one stride: the list's own width, but a
        # link (PoolShape#link_lists) is kept as the slot times the stride, so the next thing's place
        # is read straight into an index, and that takes two bytes, NONE being $FFFF.
        def self.stored_bytes(shape, list, width)
          bytes = Build::ELEMENT_BYTES.fetch(width)
          shape.link_lists.include?(list) ? [bytes, 2].max : bytes
        end

        # Where +list+ of +shape+ is at +offset+ in +area+, at +stride+: a link kept as the slot times
        # the stride, any other list as the tree holds it.
        def self.strided_place(shape, list, width, area:, offset:, stride:)
          link = shape.link_lists.include?(list)
          SlotPlace.new(area: area, offset: offset, stride: stride, width: stored_bytes(shape, list, width),
                        scale: link ? stride : 1)
        end

        # Tables side by side: each slot list in an area of its own, as :lists, but every slot as wide
        # as the pool's widest list, so one index, the slot number times that stride, reaches the same
        # thing's slot in any of them. Each value keeps its own width at the front of its slot, and the
        # links are kept scaled. A pool whose slots would all be one width is already kept so, and
        # stays :lists.
        class Tables
          def name = :tables

          def fits?(shape, steps)
            widths = stored_widths(shape)
            widths.uniq.length > 1 && PoolLayout.strided_fits?(shape, steps, widths.length * shape.capacity * widths.max)
          end

          def place(shape)
            stride = stored_widths(shape).max
            places = shape.slot_lists.to_h do |list, width|
              [list, PoolLayout.strided_place(shape, list, width, area: list, offset: 0, stride: stride)]
            end
            Placement.new(layout: name, areas: places.keys.to_h { |list| [list, shape.capacity * stride] }, slots: places)
          end

          def stored_widths(shape) = shape.slot_lists.map { |list, width| PoolLayout.stored_bytes(shape, list, width) }
        end

        # A record for each thing: every slot list of the pool in one area, the thing's values side by
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
            area = DerivedNames.join(shape.name, " records")
            offset = 0
            widest_first = shape.slot_lists.sort_by { |list, width| [-PoolLayout.stored_bytes(shape, list, width), list.to_s] }
            places = widest_first.to_h do |list, width|
              place = PoolLayout.strided_place(shape, list, width, area: area, offset: offset, stride: stride)
              offset += place.width
              [list, place]
            end
            Placement.new(layout: name, areas: { area => shape.capacity * stride }, slots: places)
          end

          def record_bytes(shape)
            bytes = shape.slot_lists.sum { |list, width| PoolLayout.stored_bytes(shape, list, width) }
            1 << (bytes - 1).bit_length
          end
        end

        # Every layout there is an adapter for, by name.
        ADAPTERS = Ractor.make_shareable({ lists: Lists.new, tables: Tables.new, records: Records.new })

        # Each console's layouts beyond :lists, with why its build keeps a pool that way: the measured
        # reason, as ControlFlow::OWN_WAYS gives its lowerings' own ways. test_pool_layout.rb holds
        # each console's Console::Description#pool_layouts to this list, both ways.
        OWN_LAYOUTS = Ractor.make_shareable(
          {
            snes: {
              tables: "One X, the slot times the pool's widest slot, reaches every field of the thing a walk " \
                      "is on, and the walk is stepped in X (SNES::Lowering#emit_stepped_walk). Measured in bsnes, " \
                      "one more pair of things checked: 1010 master clocks as lists, 532 as tables (half " \
                      "words: 900, 388); the bullets test 7.77% of a frame, 6.82%.",
              records: "A record for each thing: one X reaches every field, " \
                       "but the record's stride is the sum of the widths rounded up, more doublings to set X. " \
                       "Measured in bsnes, one more pair: 532 master clocks (half words 388); the bullets test 7.24%."
            },
            gba: {
              records: "A record for each thing, so a register on the thing a walk is on reaches every field " \
                       "with one LDR or STR at an offset, the halfword and byte loads' offsets of a byte too " \
                       "(GBA::Statements#emit_stepped_walk). Measured in the emulator, one more pair of things " \
                       "checked: 171 cycles as lists, 23 as records; a walk step 56, 4 a thing; a field moved " \
                       "on 32, 5; the bullets test 0.82% of a frame, 0.37%; five walkers 1.08%, 0.63%.",
              tables: "The pool's tables in one block, reached the same way, but a field's distance from the " \
                      "thing's slot in the first table is a table's length along, past the reach of a halfword " \
                      "or byte load's offset in a bigger pool. Measured in the emulator, one more pair: 23 " \
                      "cycles; a walk step 6, a field 11; the bullets test 0.38%; five walkers 0.63%."
            },
            gbc: {
              tables: "Each table in a page of its own, so a field of the thing a walk is on is HL with H the " \
                      "page and L the table's low byte plus the thing's distance, and the walk steps by its links " \
                      "(GBC::Lowering#emit_stepped_walk). Measured in the emulator, one more pair of things checked: " \
                      "932 cycles as lists, 604 as tables; the bullets test 15.71% of a frame, 10.17%; five " \
                      "walkers 20.41%, 15.79%.",
              records: "A record for each thing, reached the same way, but the record's stride is the sum of the " \
                       "widths rounded up, so fewer things fit the one page it must keep to. Measured in the " \
                       "emulator, one more pair: 678 cycles; five walkers 16.68%; the bullets' pool is past a page " \
                       "and keeps :lists."
            },
            genesis: {
              tables: "The pool's tables in one block, so one address register on the thing a walk is on reaches " \
                      "every field at a distance written in the instruction, and the walk steps by its links " \
                      "(Genesis::Lowering#emit_stepped_walk). Measured in Genesis Plus GX, one more pair of things " \
                      "checked: 558 cycles as lists, 264 as tables; the bullets test 7.87% of a frame, 3.29%; " \
                      "five walkers 12.67%, 7.51%.",
              records: "A record for each thing, reached the same way, but its stride is the sum of the widths " \
                       "rounded up, more doublings to find a thing. Measured in Genesis Plus GX, one more pair: " \
                       "282 cycles; the bullets test 3.38%; five walkers 8.14%."
            },
            ps1: {
              tables: "The pool's tables in one block, so one register on the thing a walk is on reaches every " \
                      "field with one load or store at a 16-bit distance, and the walk steps by its links " \
                      "(PS1::Lowering#emit_stepped_walk). Measured in Beetle PSX, one more pair of things " \
                      "checked: 96 cycles as lists, 51 as tables; a walk step 54, 15 a thing; a field moved on " \
                      "25, 11; the bullets test 0.37% of a frame, 0.21%; five walkers 0.55%, 0.36%.",
              records: "A record for each thing, reached the same way and measured the same: 51 cycles a pair, " \
                       "a walk step 15, a field 11; the bullets test 0.21%; five walkers 0.36%. No cheaper than " \
                       "tables, so tables stay first, as on the other consoles whose numbers tie."
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
