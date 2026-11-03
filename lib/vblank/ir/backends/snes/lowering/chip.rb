# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        class Lowering
          # ROUTINES THAT RUN ON THE SUPER FX, from the console's side. A routine marked `on_chip:
          # true`, on a cartridge with that chip, is made by ChipCode. Here it is still a routine like
          # any other: its label is 65816 code, which any call reaches. That code copies the
          # variables the chip needs into the chip's RAM, runs the chip until it stops, and copies
          # back the ones it can have changed. The console waits in between (Runtime::Chip).
          #
          # A LIST THE CHIP REACHES LIVES IN THE CHIP'S RAM, at the top of the block of numbers, for
          # the whole game. The chip cannot see the console's work RAM, and the console can see the
          # chip's RAM whenever the chip is stopped, by a long address like any other list's. So the
          # console's own code and Runtime::Lists reach such a list unchanged, and a run copies
          # nothing of it either way. The chip reaches a table where it is, in the cartridge.
          #
          # On any other cartridge there is no chip, the word means nothing, and the routine is made
          # as usual. A step the chip cannot do is refused here, in plain words, rather than run on the
          # console instead: the author asked for this routine to be quick, and would find it slow
          # with nothing to say why.
          module Chip
            # The kinds of IR a routine on the chip can hold besides what ChipCode makes, which say
            # nothing while the game runs.
            MADE = Ractor.make_shareable((ChipCode::STATEMENTS.keys + ChipCode::VALUES.keys + [:else]).to_h { |kind| [kind, true] })
            LIST_STEPS = %i[list_get list_set list_len list_push list_drop list_fill list_copy].freeze
            # Where each 16-bit half of a variable is, for copying.
            HALVES = [0, 2].freeze

            private

            def prepare_chip(chip)
              @chip_routines = chip ? @called.select { |name| @funcs.fetch(name).on_chip } : []
              @chip_code = nil
            end

            def on_chip?(name) = @chip_routines.include?(name)

            # Every step a run of a chip routine reaches that the chip cannot do, the first of them
            # refused by name. A routine nothing calls never runs, and is not refused.
            def refuse_what_chip_cannot_run!
              @chip_routines.each do |name|
                Reach.statements_under(@funcs.fetch(name)).each do |node|
                  next if Nodes.of_role(:declaration).include?(node.kind)

                  refuse_chip_call!(name, node.target) if node.kind == :call && !on_chip?(node.target)
                  refuse_chip_step!(name, node) unless MADE[node.kind]
                  refuse_table_in_parts!(name, node, node.name) if node.kind == :table_get
                  refuse_table_in_parts!(name, node, node.table) if node.kind == :list_copy
                end
              end
            end

            def refuse_chip_call!(name, target)
              raise LoweringError, "The routine #{name.inspect} runs on the Super FX chip. It calls the routine " \
                                   "#{target.inspect}, and that routine does not run on the chip. To fix this, add " \
                                   "on_chip: true to #{target.inspect}, or move the call out of #{name.inspect}."
            end

            def refuse_chip_step!(name, node)
              where = node.source ? " (#{node.source})" : ""
              raise LoweringError, "The routine #{name.inspect} runs on the Super FX chip. It has a step that the chip " \
                                   "cannot do: #{chip_step_words(node)}#{where}. To fix this, move the step out of " \
                                   "#{name.inspect}. Do the step before or after the call."
            end

            # A read by index, or a run copied into a list, of the table +table_name+.
            def refuse_table_in_parts!(name, node, table_name)
              table = @tables.fetch(table_name) { return }
              return unless split?(table)

              what = node.kind == :list_copy ? "copy" : "read"
              raise LoweringError, "The routine #{name.inspect} runs on the Super FX chip, and it reads the table " \
                                   "#{table_name.inspect}. That table is bigger than a bank of the cartridge, and the " \
                                   "chip reads a table from one bank only. To fix this, cut the table into tables " \
                                   "of 32K or less, or move the #{what} out of #{name.inspect}."
            end

            def chip_step_words(node)
              kind = node.kind
              return "a wait for the next frame" if kind == :wait_vblank
              return "a change of scene (case_var), and a scene sets up the screen, which only the console can do" if kind == :case
              return "a drawing step (#{kind})" if node.category == :draw
              return "a sound step (#{kind})" if node.category == :sound

              "the step #{kind}"
            end

            # The lists a run of a chip routine reads or writes, by name.
            def chip_list_names
              @chip_routines.flat_map do |name|
                Reach.statements_under(@funcs.fetch(name)).filter_map { |node| node.name if LIST_STEPS.include?(node.kind) }
              end.uniq
            end

            # The 16-bit place in the chip's RAM of each list the chip reaches, from the top of the
            # block of numbers down, each at a multiple of four so its words are whole words to the
            # chip. Refused when they leave no room.
            def place_chip_lists
              @chip_lists = {}
              @chip_numbers_end = ChipCode::NUMBERS_END
              chip_list_names.each do |name|
                node = @declared_lists.fetch(name) { next }
                width = LoweringPlan::SLOT_BYTES.fetch(node.width)
                at = (@chip_numbers_end - Runtime::Lists::HEADER - (node.capacity * width)) & ~3
                refuse_chip_lists_too_big!(name) if at < ChipCode::FIRST_NUMBER + CHIP_NUMBERS_KEPT
                @chip_numbers_end = at
                @chip_lists[name] = ChipCode::ListPlace.new(at: at, width: width, ring: front_dropped_lists.include?(name))
              end
            end

            # Room the lists leave for the numbers a run copies in and keeps for itself.
            CHIP_NUMBERS_KEPT = 0x400

            def refuse_chip_lists_too_big!(name)
              room = ChipCode::NUMBERS_END - ChipCode::FIRST_NUMBER - CHIP_NUMBERS_KEPT
              raise LoweringError, "The list #{name.inspect} is used on the Super FX chip, and the lists the chip " \
                                   "uses do not fit in its RAM. Those lists and the chip's numbers share " \
                                   "#{ChipCode::NUMBERS_END - ChipCode::FIRST_NUMBER} bytes, and " \
                                   "the lists can take #{room} bytes of it. To fix this, give those lists smaller " \
                                   "capacities, or use #{name.inspect} only outside the routines marked on_chip: true."
            end

            # Where a list the chip reaches lives: its long address in the chip's RAM.
            def chip_list_place(name) = @chip_lists && @chip_lists[name] && chip_ram_address(@chip_lists[name].at)

            # The chip's code, as sections for the Linker: none for a game with nothing to run there.
            def chip_sections
              return [] if @chip_routines.empty?

              [@chip_code.section]
            end

            def make_chip_code
              return if @chip_routines.empty?

              tables = @tables.values.to_h do |table|
                bytes, signed = table_keeping(table)
                [table.name, ChipCode::TableRead.new(label: table_label(table.name), count: table.values.length,
                                                     bytes: bytes, signed: signed)]
              end
              columns = chip_column_pictures.to_h do |name|
                image = Assets::Image.of(picture_named(name))
                [name, ChipCode::ColumnPicture.new(width: image.width, height: image.height, starts: "column starts of #{name}")]
              end
              @chip_code = ChipCode.new(routines: @chip_routines, funcs: @funcs, plan: @plan, holds: ROUTINES,
                                        tables: tables, lists: @chip_lists, columns: columns, numbers_end: @chip_numbers_end)
            end

            # The pictures a run of a chip routine draws columns of (draw_column_at), by name.
            def chip_column_pictures
              @chip_routines.flat_map do |name|
                Reach.statements_under(@funcs.fetch(name)).filter_map { |node| node.name if node.kind == :draw_column_at }
              end.uniq
            end

            # The 65816 routine that stands for +name+.
            def chip_routine_section(name)
              routine_section(self.class.routine_label(name), [], routine: routine_said(name)) { emit_chip_run(name) }
            end

            def emit_chip_run(name)
              faults = @chip_code.faults?(name)
              if faults
                @asm.lda(0)
                @asm.sta(@asm.long(chip_ram_address(@chip_code.fault_list_place)))
              end
              @chip_code.variables_sent(name).product(HALVES).each do |(variable, at), half|
                @asm.lda(at_place(place_of(variable) + half))
                @asm.sta(@asm.long(chip_ram_address(at) + half))
              end
              paints = @chip_code.paints?(name)
              emit_paint_handed_to_chip if paints
              value(LongAddress.new(ChipCode.entry_label(name)))
              call_routine("rt_chip_run")
              @chip_code.variables_changed(name).product(HALVES).each do |(variable, at), half|
                @asm.lda(@asm.long(chip_ram_address(at) + half))
                @asm.sta(at_place(place_of(variable) + half))
              end
              emit_paint_taken_from_chip if paints
              emit_chip_fault_check(name) if faults
            end

            # What a run that paints needs of the painted screen, which the chip cannot see in work
            # RAM (Runtime::ChipColumns): the area painting is held to, the screen's generation, the
            # clear colour's planes, and each row of tiles' changed tiles. No tile is made ready yet.
            def emit_paint_handed_to_chip
              paint = Runtime::Paint
              places = @chip_code.paint_places
              area = @memory[paint::AREA]
              @chip_code.area_places.each_with_index do |at, edge|
                @asm.lda(@asm.abs(area + (edge * 2)))
                @asm.sta(@asm.long(chip_ram_address(at)))
                @asm.lda(0)
                @asm.sta(@asm.long(chip_ram_address(at) + 2))
              end
              @asm.lda(@asm.abs(@memory[paint::GENERATION]))
              @asm.sta(@asm.long(chip_ram_address(places.generation)))
              4.times do |pair|
                @asm.lda(@asm.abs(@memory[paint::CLEAR_PLANES] + (pair * 2)))
                @asm.sta(@asm.long(chip_ram_address(places.clear) + (pair * 2)))
              end
              @asm.lda(0)
              @asm.sta(@asm.long(chip_ram_address(places.readied_count)))
              emit_dirty_copied(to_chip: true)
            end

            # What a run that painted changed of the painted screen: the changed tiles of each row,
            # and the map's cell of each tile the chip made ready pointed back at that tile, as
            # Runtime::Paint's rt_paint_ready does.
            def emit_paint_taken_from_chip
              paint = Runtime::Paint
              places = @chip_code.paint_places
              emit_dirty_copied(to_chip: false)
              none = fresh("none_readied")
              tile = fresh("readied_tile")
              @asm.lda(@asm.long(chip_ram_address(places.readied_count)))
              @asm.beq(none)
              @asm.sta(@asm.direct(R0))
              @asm.ldx(0)
              @asm.label(tile)
              @asm.phx
              @asm.lda(@asm.long_x(chip_ram_address(places.readied)))
              @asm.pha
              @asm.asl
              @asm.tax
              @asm.pla
              @asm.sta(@asm.long_x(@memory[paint::MAP_COPY]))
              @asm.plx
              @asm.inx
              @asm.inx
              @asm.cpx(@asm.direct(R0))
              @asm.bne(tile)
              @asm.lda(1)
              @asm.sta(@asm.abs(@memory[paint::MAP_CHANGED]))
              @asm.label(none)
            end

            # Each row of tiles' leftmost and rightmost changed tile (Runtime::Paint's DIRTY), copied
            # into the chip's RAM or back.
            def emit_dirty_copied(to_chip:)
              dirty = @memory[Runtime::Paint::DIRTY]
              chip = chip_ram_address(@chip_code.paint_places.dirty)
              word = fresh("dirty_word")
              @asm.ldx(0)
              @asm.label(word)
              @asm.lda(to_chip ? @asm.abs_x(dirty) : @asm.long_x(chip))
              @asm.sta(to_chip ? @asm.long_x(chip) : @asm.abs_x(dirty))
              @asm.inx
              @asm.inx
              @asm.cpx(Runtime::Paint::ROWS * 4)
              @asm.bne(word)
            end

            # A list the chip found at fault stops the game here, in Runtime::Lists's words. An index
            # outside it: the list's place in X and Y and the index in R1, as rt_list_outside takes
            # them. An item added to it full, or taken from it empty: the chip left the list as it
            # was, so the runtime's own push, or its drop from the same end (R1), finds the same fault
            # and stops the game as it does for the console's own code.
            def emit_chip_fault_check(name)
              fine = fresh("chip_fine")
              @asm.lda(@asm.long(chip_ram_address(@chip_code.fault_list_place)))
              @asm.beq(fine)
              @asm.tax
              index = chip_ram_address(@chip_code.fault_index_place)
              HALVES.each do |half|
                @asm.lda(@asm.long(index + half))
                @asm.sta(@asm.direct(Memory.register(1) + half))
              end
              emit_chip_end_fault_check if @chip_code.faults_at_ends?(name)
              @asm.ldy(Console::SNESHardware::GSU_RAM_BANK)
              call_routine("rt_list_outside")
              @asm.label(fine)
            end

            # With the list's place in X: on to the index fault below unless the chip said the list was
            # full or empty, and otherwise the runtime's push or drop on that list, which never return.
            def emit_chip_end_fault_check
              at_index = fresh("chip_index_fault")
              empty = fresh("chip_empty_fault")
              @asm.stx(@asm.direct(R0))
              @asm.ldy(Console::SNESHardware::GSU_RAM_BANK)
              @asm.sty(@asm.direct(R0 + 2))
              @asm.lda(@asm.long(chip_ram_address(@chip_code.fault_kind_place)))
              @asm.beq(at_index)
              @asm.cmp(ChipCode::FAULT_KINDS.fetch(:full))
              @asm.bne(empty)
              call_routine("rt_list_push")
              @asm.label(empty)
              call_routine("rt_list_drop")
              @asm.label(at_index)
            end

            def chip_ram_address(at) = Runtime::ChipPaint::COPY | at
          end
        end
      end
    end
  end
end
