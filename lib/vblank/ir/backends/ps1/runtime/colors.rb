# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE COLOURS A SCREEN DRAWN FROM TILES CHANGES AS IT RUNS: a list of colours told to hold another
          # set (`recolor`, Nodes::ColorListHolds), a background drawn with another list (`draw_with`,
          # Nodes::BackgroundColors), and a fade or a tint. Everything such a screen shows is read through a
          # colour table in video RAM, its backgrounds (PS1::PlaneColors) and its sprites alike, and the
          # backdrop is one colour; so each of these is the tables written again, as a Genesis or a Super
          # Nintendo writes its colour memory. A painted screen that fades or tints is drawn by number
          # (PS1::PaintedNumbers) and read through one such table as it is shown, which is walked the same way,
          # and has no backdrop of its own.
          #
          # The game's own colours, every table's entries as the game holds them now, are kept in RAM ("colors
          # base", a halfword an entry as the chip reads it, see-through 0000h; the backdrop first, then each
          # table), and the tables shown are worked out from them: each colour moved by the fade or tint in
          # force (PaletteWalk; Reference#exec_fade and #exec_tint walk every colour of the picture the same
          # way, Framebuffer#walked_toward and #mixed), into "colors shown", and copied into video RAM.
          #
          #   toward black   c - (c × steps ÷ 256)
          #   toward white   c + ((31 - c) × steps ÷ 256)
          #   toward a tint  (c × (256 - steps) + tint × steps) ÷ 256
          #
          # All three are one sum, (c × keep + add) ÷ 256 with keep = 256 - steps: the add is 255 toward
          # black (c less a share rounded down is the share kept rounded up), 31 × steps toward white and the
          # tint's channel × steps toward a tint. So a walk is worked out once, when it changes, for each of
          # the 32 values a channel holds, into a table for each channel already in its place in a colour
          # (WALK_TABLES, rt_colors_walk_tables), and a colour is then three halfwords read and put together
          # (rt_colors_walk), with no multiply and no call for each.
          #
          # A change only marks what it changed (DIRTY): a list or a background told another set marks the
          # colour tables its entries are in (each table's record in "colors tables") and the backdrop if it is
          # one, a fade or tint every one. They are worked out once, as the pass's picture is drawn
          # (rt_colors_shown, the first thing rt_tiles_draw does), and only the tables marked are walked and
          # copied, before anything of the picture is, so they show on the picture of the pass that changed
          # them, as the interpreter's do, and a pass that changes them several times works them out once. A
          # pass that changes nothing costs one test. That is PaletteWalk's rule, worked out as the pass ends
          # and sent before its picture shows: the PlayStation draws a pass's whole picture as the pass ends,
          # so that is the moment it is sent.
          #
          #   rt_tint_to(toward, steps, color)  a0 = PaletteWalk's toward, a1 the steps in 256ths, a2 the colour
          #   rt_colors_hold(source, which)     a0 = a source's table, a1 = the set the game names
          #   rt_colors_shown                   as the picture is drawn: the tables marked worked out and copied
          #
          # A SOURCE is one thing whose number picks a set: a list of colours, or a background's own lists. Its
          # table, made while the game is built (Lowering::Picture#color_sections), is the set it holds now (a
          # word, 0 for the colours it was declared with), how many sets it has besides those, how many entries
          # it changes (m), how many colour tables those are in (k); then k words, each a table's record in
          # "colors tables" or nought for the backdrop; m words, each the place in "colors base" of an entry,
          # in bytes; then each set's m colours, a halfword each. A number naming no set is the declared
          # colours (Reference#colors_held_by), and a set a source holds already costs nothing, so a game
          # naming its set every pass pays nothing.
          module Colors
            # The fade or tint in force, a word each: toward what, its steps and its colour; then what the
            # colours shown must have worked out again (nought nothing, DIRTY_ALL every table, DIRTY_MARKED
            # the tables marked); whether WALK_TABLES hold the walk in force; whether the backdrop is marked.
            WALK = "rt colors walk"
            MODE = 0
            STEPS = 4
            COLOR = 8
            DIRTY = 12
            TABLES_BUILT = 16
            BACKDROP_MARKED = 20
            WALK_BYTES = 24
            DIRTY_ALL = 1
            DIRTY_MARKED = 2

            # The walk in force for each value a channel holds, red's 32 halfwords, then green's, then blue's,
            # each already in its place in a colour, red's with the chip's drawn bit (TEXEL_DRAWN) set.
            WALK_TABLES = "rt colors walk tables"
            WALK_TABLE_BYTES = 64

            TOWARD_BLACK = PaletteWalk::TOWARD_BLACK
            TOWARD_WHITE = PaletteWalk::TOWARD_WHITE

            # What the lowering's tables are called (Lowering::Picture#color_sections): the game's colours and
            # the ones shown, a halfword an entry, the backdrop's first; how many halfwords each holds; and the
            # tables to copy, how many, then for each (its record, labelled #table_record) where it goes in
            # video RAM (y << 16 | x), its size as the copy takes it (1 << 16 | entries), where it starts in
            # "colors shown" in bytes, its words, and whether it is marked to be worked out and copied.
            BASE = "colors base"
            SHOWN = "colors shown"
            HALFWORDS = "colors halfwords"
            TABLES = "colors tables"
            TABLE_SIZE = 4
            TABLE_START = 8
            TABLE_MARKED = 16
            TABLE_BYTES = 20
            # A source's table: the set it holds, how many sets besides the declared, how many entries it
            # changes, how many colour tables they are in.
            SOURCE_HELD = 0
            SOURCE_SETS = 4
            SOURCE_ENTRIES = 8
            SOURCE_TABLES = 12
            SOURCE_HEADER_BYTES = 16

            module_function

            # The label of colour table +at+'s record in "colors tables".
            def table_record(at) = "colors table #{at}"

            def reserve(memory)
              memory.reserve(WALK, WALK_BYTES)
              memory.reserve(WALK_TABLES, 3 * WALK_TABLE_BYTES)
            end

            # +backdrop+ for a screen drawn from tiles, whose backdrop is the first colour; a painted screen drawn
            # by number (PS1::PaintedNumbers) has none.
            def emit(asm, memory, backdrop: true)
              at = ->(offset) { Runtime.at(memory, WALK) + offset }
              tables = Runtime.at(memory, WALK_TABLES)
              emit_tint_to(asm, at)
              emit_hold(asm, at)
              emit_walk_tables(asm, at, tables)
              emit_walk(asm, tables)
              emit_shown(asm, memory, at, backdrop)
            end

            # rt_tint_to: the fade or tint in force from now on. Asked for the same as the one in force, it does
            # nothing; no steps at all is the colours as they are, whatever they were walked toward (PaletteWalk).
            def emit_tint_to(asm, at)
              asm.label("rt_tint_to")
              asm.lw(:t0, at.call(STEPS), :gp)
              asm.bne(:t0, :a1, "rt_tint_to_changed")
              asm.beq(:a1, :zero, "rt_tint_to_same")
              asm.lw(:t0, at.call(MODE), :gp)
              asm.bne(:t0, :a0, "rt_tint_to_changed")
              asm.lw(:t0, at.call(COLOR), :gp)
              asm.bne(:t0, :a2, "rt_tint_to_changed")
              asm.label("rt_tint_to_same")
              asm.jr(:ra)
              asm.label("rt_tint_to_changed")
              asm.sw(:a0, at.call(MODE), :gp)
              asm.sw(:a1, at.call(STEPS), :gp)
              asm.sw(:a2, at.call(COLOR), :gp)
              asm.sw(:zero, at.call(TABLES_BUILT), :gp)
              asm.li(:t0, DIRTY_ALL)
              asm.jr(:ra) { asm.sw(:t0, at.call(DIRTY), :gp) }
            end

            # rt_colors_hold: the source a0 holds the set a1 names, its colours written into "colors base", and
            # the tables they are in marked.
            def emit_hold(asm, at)
              asm.label("rt_colors_hold")
              asm.lw(:t0, SOURCE_SETS, :a0)
              asm.sltu(:t1, :a1, :t0)
              asm.bne(:t1, :zero, "rt_colors_hold_chosen") { asm.addiu(:t2, :a1, 1) }
              asm.move(:t2, :zero)
              asm.label("rt_colors_hold_chosen")
              asm.lw(:t3, SOURCE_HELD, :a0)
              asm.beq(:t3, :t2, "rt_colors_hold_done")
              asm.sw(:t2, SOURCE_HELD, :a0)
              asm.lw(:t4, SOURCE_ENTRIES, :a0)
              asm.lw(:t0, SOURCE_TABLES, :a0)
              asm.addiu(:t7, :a0, SOURCE_HEADER_BYTES) # the tables its entries are in
              asm.sll(:t5, :t0, 2)
              asm.addu(:t5, :t5, :t7) # its entries' places
              asm.sll(:t6, :t4, 2)
              asm.addu(:t6, :t6, :t5)
              asm.mult(:t2, :t4)
              asm.mflo(:t3)
              asm.sll(:t3, :t3, 1)
              asm.addu(:t6, :t6, :t3) # the set's colours
              asm.la(:t8, BASE)
              asm.label("rt_colors_hold_entry")
              asm.beq(:t4, :zero, "rt_colors_hold_mark")
              asm.lw(:t9, 0, :t5)
              asm.addu(:t9, :t9, :t8)
              asm.lhu(:t1, 0, :t6)
              asm.sh(:t1, 0, :t9)
              asm.addiu(:t5, :t5, 4)
              asm.addiu(:t6, :t6, 2)
              asm.b("rt_colors_hold_entry") { asm.addiu(:t4, :t4, -1) }
              # Each table the entries are in marked, nought the backdrop.
              asm.label("rt_colors_hold_mark")
              asm.li(:t1, 1)
              asm.label("rt_colors_hold_table")
              asm.beq(:t0, :zero, "rt_colors_hold_dirty")
              asm.lw(:t9, 0, :t7)
              asm.bne(:t9, :zero, "rt_colors_hold_record")
              asm.addiu(:t9, :gp, at.call(BACKDROP_MARKED) - TABLE_MARKED) # the backdrop's mark, in a record's place
              asm.label("rt_colors_hold_record")
              asm.sw(:t1, TABLE_MARKED, :t9)
              asm.addiu(:t7, :t7, 4)
              asm.b("rt_colors_hold_table") { asm.addiu(:t0, :t0, -1) }
              asm.label("rt_colors_hold_dirty")
              asm.lw(:t0, at.call(DIRTY), :gp)
              asm.ori(:t0, :t0, DIRTY_MARKED)
              asm.sw(:t0, at.call(DIRTY), :gp)
              asm.label("rt_colors_hold_done")
              asm.jr(:ra)
            end

            # rt_colors_walk_tables: WALK_TABLES worked out for the walk in force. Each channel's sum starts at
            # its add and goes up by keep for each of the 32 values, and its top bits past the eighth are the
            # value walked. Changes t0 to t8.
            def emit_walk_tables(asm, at, tables)
              h = Console::PS1Hardware
              asm.label("rt_colors_walk_tables")
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(TABLES_BUILT), :gp)
              asm.lw(:t0, at.call(STEPS), :gp)
              asm.li(:t1, 256)
              asm.subu(:t1, :t1, :t0) # keep
              asm.lw(:t2, at.call(MODE), :gp)
              asm.lw(:t3, at.call(COLOR), :gp)
              3.times do |channel|
                summed = "rt_colors_walk_tables_summed_#{channel}"
                lighter = "rt_colors_walk_tables_lighter_#{channel}"
                filled = "rt_colors_walk_tables_#{channel}"
                asm.beq(:t2, :zero, summed) { asm.li(:t5, 255) } # toward black
                asm.li(:t7, TOWARD_WHITE)
                asm.beq(:t2, :t7, lighter) { asm.li(:t6, 31) }
                asm.srl(:t6, :t3, 5 * channel) # toward a tint: its channel
                asm.andi(:t6, :t6, 31)
                asm.label(lighter)
                asm.mult(:t6, :t0)
                asm.mflo(:t5)
                asm.label(summed)
                asm.li(:t6, 32)
                asm.addiu(:t7, :gp, tables + (channel * WALK_TABLE_BYTES))
                asm.label(filled)
                asm.srl(:t8, :t5, 8)
                asm.sll(:t8, :t8, 5 * channel) if channel.positive?
                asm.ori(:t8, :t8, h::TEXEL_DRAWN) if channel.zero?
                asm.sh(:t8, 0, :t7)
                asm.addu(:t5, :t5, :t1)
                asm.addiu(:t6, :t6, -1)
                asm.bgtz(:t6, filled) { asm.addiu(:t7, :t7, 2) }
              end
              asm.jr(:ra)
            end

            # rt_colors_walk: a2 halfwords of "colors base" from a0 walked into "colors shown" at a1, see-through
            # left see-through and every other drawn (Console::PS1Hardware::TEXEL_DRAWN, in red's table). A
            # colour is its three channels' halfwords read from WALK_TABLES at the channel's value, the drawn bit
            # of the game's colour passed over. Changes a0 to a2 and t0 to t4.
            def emit_walk(asm, tables)
              asm.label("rt_colors_walk")
              asm.addiu(:t4, :gp, tables)
              asm.label("rt_colors_walk_entry")
              asm.lhu(:t0, 0, :a0)
              asm.beq(:t0, :zero, "rt_colors_walk_store") { asm.move(:v0, :zero) }
              asm.andi(:t1, :t0, 31)
              asm.sll(:t1, :t1, 1)
              asm.addu(:t1, :t1, :t4)
              asm.lhu(:v0, 0, :t1)
              asm.srl(:t1, :t0, 4) # green's value, two bytes an entry
              asm.andi(:t1, :t1, 62)
              asm.addu(:t1, :t1, :t4)
              asm.lhu(:t2, WALK_TABLE_BYTES, :t1)
              asm.srl(:t1, :t0, 9) # blue's
              asm.andi(:t1, :t1, 62)
              asm.addu(:t1, :t1, :t4)
              asm.lhu(:t3, 2 * WALK_TABLE_BYTES, :t1)
              asm.or(:v0, :v0, :t2)
              asm.or(:v0, :v0, :t3)
              asm.label("rt_colors_walk_store")
              asm.sh(:v0, 0, :a1)
              asm.addiu(:a0, :a0, 2)
              asm.addiu(:a2, :a2, -1)
              asm.bgtz(:a2, "rt_colors_walk_entry") { asm.addiu(:a1, :a1, 2) }
              asm.jr(:ra)
            end

            SHOWN_KEPT = %i[s0 s1 s2 s3].freeze

            # rt_colors_shown: if anything is marked, the walk's tables worked out again if the walk changed;
            # every table and the backdrop marked if the walk changed; the backdrop, if marked, walked and its
            # fill set; and each table marked walked from "colors base" into "colors shown" and copied into video
            # RAM, once the chip has drawn everything sent before, as Paint's rt_paint_upload copies the
            # pictures at power-on.
            def emit_shown(asm, memory, at, backdrop)
              asm.label("rt_colors_shown")
              asm.lw(:t0, at.call(DIRTY), :gp)
              asm.bne(:t0, :zero, "rt_colors_shown_dirty")
              asm.jr(:ra)
              asm.label("rt_colors_shown_dirty")
              asm.sw(:zero, at.call(DIRTY), :gp)
              asm.addiu(:sp, :sp, -4 * (SHOWN_KEPT.length + 1))
              asm.sw(:ra, 0, :sp)
              SHOWN_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.move(:s3, :t0)
              asm.lw(:t0, at.call(TABLES_BUILT), :gp)
              asm.beq(:t0, :zero, "rt_colors_shown_walk_owed")
              asm.label("rt_colors_shown_walk_kept")
              emit_all_marked(asm, at)
              emit_backdrop_walked(asm, memory, at) if backdrop
              emit_tables_copied(asm)
              asm.lw(:ra, 0, :sp)
              SHOWN_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (SHOWN_KEPT.length + 1)) }
              asm.label("rt_colors_shown_walk_owed")
              asm.jal("rt_colors_walk_tables")
              asm.b("rt_colors_shown_walk_kept")
            end

            # After a change of the walk (DIRTY_ALL in s3), every table and the backdrop marked.
            def emit_all_marked(asm, at)
              asm.andi(:t0, :s3, DIRTY_ALL)
              asm.beq(:t0, :zero, "rt_colors_shown_marked")
              asm.li(:t1, 1)
              asm.sw(:t1, at.call(BACKDROP_MARKED), :gp)
              asm.la(:t2, TABLES)
              asm.lw(:t3, 0, :t2)
              asm.label("rt_colors_shown_mark")
              asm.beq(:t3, :zero, "rt_colors_shown_marked")
              asm.sw(:t1, 4 + TABLE_MARKED, :t2)
              asm.addiu(:t2, :t2, TABLE_BYTES)
              asm.b("rt_colors_shown_mark") { asm.addiu(:t3, :t3, -1) }
              asm.label("rt_colors_shown_marked")
            end

            # The backdrop, if marked, walked into the first colour shown and its fill command (Tiles::BACKDROP)
            # set from it: each five-bit channel at the top of its byte (Console::PS1Hardware.command_color).
            def emit_backdrop_walked(asm, memory, at)
              h = Console::PS1Hardware
              asm.lw(:t0, at.call(BACKDROP_MARKED), :gp)
              asm.beq(:t0, :zero, "rt_colors_shown_backdrop_kept")
              asm.sw(:zero, at.call(BACKDROP_MARKED), :gp)
              asm.la(:a0, BASE)
              asm.la(:a1, SHOWN)
              asm.jal("rt_colors_walk") { asm.li(:a2, 1) }
              asm.la(:t0, SHOWN)
              asm.lhu(:t0, 0, :t0)
              asm.lui(:v0, h::GP0_FILL >> 16)
              [3, 11, 19].each_with_index do |shift, channel|
                asm.srl(:t1, :t0, 5 * channel)
                asm.andi(:t1, :t1, 31)
                asm.sll(:t1, :t1, shift)
                asm.or(:v0, :v0, :t1)
              end
              asm.sw(:v0, Runtime.at(memory, Tiles::BACKDROP), :gp)
              asm.label("rt_colors_shown_backdrop_kept")
            end

            # Each table in "colors tables" that is marked walked (rt_colors_walk) and copied from "colors shown"
            # into video RAM: its command's three words to the port, then its colours by the DMA, in blocks of
            # one word, waiting for each to be sent (psx-spx, "GPU Memory Transfer Commands", GP0(A0h)).
            def emit_tables_copied(asm)
              h = Console::PS1Hardware
              asm.jal("rt_draw_list_finish")
              asm.la(:s0, TABLES)
              asm.lw(:s2, 0, :s0)
              asm.addiu(:s0, :s0, 4)
              asm.label("rt_colors_shown_table")
              asm.beq(:s2, :zero, "rt_colors_shown_tables_done")
              asm.lw(:t0, TABLE_MARKED, :s0)
              asm.beq(:t0, :zero, "rt_colors_shown_table_next")
              asm.sw(:zero, TABLE_MARKED, :s0)
              asm.lw(:s1, TABLE_START, :s0)
              asm.la(:a0, BASE)
              asm.addu(:a0, :a0, :s1)
              asm.la(:a1, SHOWN)
              asm.addu(:s1, :s1, :a1) # where its colours shown start
              asm.lhu(:a2, TABLE_SIZE, :s0) # its entries, the size's low half
              asm.jal("rt_colors_walk") { asm.move(:a1, :s1) }
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_COPY_TO_VRAM >> 16) }
              asm.lui(:t5, h::IO >> 16)
              asm.lw(:t0, 0, :s0)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t5)
              asm.lw(:t0, TABLE_SIZE, :s0)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t5)
              asm.sw(:s1, h::DMA2_MADR & 0xFFFF, :t5)
              asm.lw(:t0, 12, :s0)
              asm.sll(:t0, :t0, 16)
              asm.ori(:t0, :t0, 1) # blocks of one word, as many as the colours take
              asm.sw(:t0, h::DMA2_BCR & 0xFFFF, :t5)
              asm.li(:t0, h::DMA2_FROM_RAM_BY_BLOCKS)
              asm.sw(:t0, h::DMA2_CHCR & 0xFFFF, :t5)
              asm.lui(:t1, h::DMA_BUSY >> 16)
              asm.label("rt_colors_shown_table_wait")
              asm.lw(:t0, h::DMA2_CHCR & 0xFFFF, :t5)
              asm.and(:t0, :t0, :t1)
              asm.bne(:t0, :zero, "rt_colors_shown_table_wait")
              asm.label("rt_colors_shown_table_next")
              asm.addiu(:s0, :s0, TABLE_BYTES)
              asm.b("rt_colors_shown_table") { asm.addiu(:s2, :s2, -1) }
              asm.label("rt_colors_shown_tables_done")
            end
          end
        end
      end
    end
  end
end
