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
          # Nintendo writes its colour memory.
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
          # A change only marks the colours owed (DIRTY). They are worked out once, as the pass's picture is
          # drawn (rt_colors_shown, the first thing rt_tiles_draw does), and copied before anything of it is,
          # so they show on the picture of the pass that changed them, as the interpreter's do, and a pass
          # that changes them several times works them out once. A pass that changes nothing costs one test.
          #
          #   rt_tint_to(toward, steps, color)  a0 = PaletteWalk's toward, a1 the steps in 256ths, a2 the colour
          #   rt_colors_hold(source, which)     a0 = a source's table, a1 = the set the game names
          #   rt_colors_shown                   as the picture is drawn: the tables worked out and copied
          #
          # A SOURCE is one thing whose number picks a set: a list of colours, or a background's own lists. Its
          # table, made while the game is built (Lowering::Picture#color_sections), is the set it holds now (a
          # word, 0 for the colours it was declared with), how many sets it has besides those, how many entries
          # it changes (m), then m words, each the place in "colors base" of an entry, in bytes, then each set's
          # m colours, a halfword each. A number naming no set is the declared colours (Reference#colors_held_by),
          # and a set a source holds already costs nothing, so a game naming its set every pass pays nothing.
          module Colors
            WALK = "rt colors walk" # The fade or tint in force: toward what, its steps, its colour; and whether
            MODE = 0 #                the colours are owed, a word each
            STEPS = 4
            COLOR = 8
            DIRTY = 12
            WALK_BYTES = 16

            TOWARD_BLACK = PaletteWalk::TOWARD_BLACK
            TOWARD_WHITE = PaletteWalk::TOWARD_WHITE

            # What the lowering's tables are called (Lowering::Picture#color_sections): the game's colours and
            # the ones shown, a halfword an entry, the backdrop's first; how many halfwords each holds; and the
            # tables to copy, how many, then for each where it goes in video RAM (y << 16 | x), its size as the
            # copy takes it (1 << 16 | entries), where it starts in "colors shown" in bytes, and its words.
            BASE = "colors base"
            SHOWN = "colors shown"
            HALFWORDS = "colors halfwords"
            TABLES = "colors tables"
            TABLE_BYTES = 16
            # A source's table: the set it holds, how many sets besides the declared, how many entries it changes.
            SOURCE_HELD = 0
            SOURCE_SETS = 4
            SOURCE_ENTRIES = 8
            SOURCE_HEADER_BYTES = 12

            module_function

            def reserve(memory)
              memory.reserve(WALK, WALK_BYTES)
            end

            def emit(asm, memory)
              at = ->(offset) { Runtime.at(memory, WALK) + offset }
              emit_tint_to(asm, at)
              emit_hold(asm, at)
              emit_walked(asm, at)
              emit_shown(asm, memory, at)
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
              asm.li(:t0, 1)
              asm.jr(:ra) { asm.sw(:t0, at.call(DIRTY), :gp) }
            end

            # rt_colors_hold: the source a0 holds the set a1 names, its colours written into "colors base".
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
              asm.addiu(:t5, :a0, SOURCE_HEADER_BYTES)
              asm.sll(:t6, :t4, 2)
              asm.addu(:t6, :t6, :t5)
              asm.mult(:t2, :t4)
              asm.mflo(:t7)
              asm.sll(:t7, :t7, 1)
              asm.addu(:t6, :t6, :t7) # the set's colours
              asm.la(:t8, BASE)
              asm.label("rt_colors_hold_entry")
              asm.beq(:t4, :zero, "rt_colors_hold_owed")
              asm.lw(:t9, 0, :t5)
              asm.addu(:t9, :t9, :t8)
              asm.lhu(:t0, 0, :t6)
              asm.sh(:t0, 0, :t9)
              asm.addiu(:t5, :t5, 4)
              asm.addiu(:t6, :t6, 2)
              asm.b("rt_colors_hold_entry") { asm.addiu(:t4, :t4, -1) }
              asm.label("rt_colors_hold_owed")
              asm.li(:t0, 1)
              asm.sw(:t0, at.call(DIRTY), :gp)
              asm.label("rt_colors_hold_done")
              asm.jr(:ra)
            end

            # rt_color_walked: a0 = a colour of the game's, 15 bits, v0 = the colour it is shown as under the fade
            # or tint in force. Each channel in turn, five bits, the fraction dropped. Changes t0 to t5.
            def emit_walked(asm, at)
              asm.label("rt_color_walked")
              asm.lw(:t0, at.call(STEPS), :gp)
              asm.bne(:t0, :zero, "rt_color_walked_moved")
              asm.jr(:ra) { asm.move(:v0, :a0) }
              asm.label("rt_color_walked_moved")
              asm.lw(:t1, at.call(MODE), :gp)
              asm.move(:v0, :zero)
              asm.li(:t5, TOWARD_WHITE)
              asm.beq(:t1, :t5, "rt_color_walked_white")
              asm.bne(:t1, :zero, "rt_color_walked_color")
              emit_channels(asm) do
                asm.mult(:t2, :t0)
                asm.mflo(:t3)
                asm.srl(:t3, :t3, 8)
                asm.subu(:t2, :t2, :t3)
              end
              asm.label("rt_color_walked_white")
              emit_channels(asm) do
                asm.li(:t3, 31)
                asm.subu(:t3, :t3, :t2)
                asm.mult(:t3, :t0)
                asm.mflo(:t3)
                asm.srl(:t3, :t3, 8)
                asm.addu(:t2, :t2, :t3)
              end
              asm.label("rt_color_walked_color")
              asm.lw(:t4, at.call(COLOR), :gp)
              asm.li(:t1, 256)
              asm.subu(:t1, :t1, :t0)
              emit_channels(asm, toward: :t4) do
                asm.mult(:t2, :t1)
                asm.mflo(:t2)
                asm.mult(:t3, :t0)
                asm.mflo(:t3)
                asm.addu(:t2, :t2, :t3)
                asm.srl(:t2, :t2, 8)
              end
            end

            # Each of a0's three channels into t2 (and +toward+'s into t3), moved by the block, and put back in
            # its place in v0; then the return.
            def emit_channels(asm, toward: nil)
              3.times do |channel|
                asm.srl(:t2, :a0, 5 * channel)
                asm.andi(:t2, :t2, 31)
                if toward
                  asm.srl(:t3, toward, 5 * channel)
                  asm.andi(:t3, :t3, 31)
                end
                yield
                asm.sll(:t2, :t2, 5 * channel)
                asm.or(:v0, :v0, :t2)
              end
              asm.jr(:ra)
            end

            SHOWN_KEPT = %i[s0 s1 s2].freeze

            # rt_colors_shown: if the colours are owed, every entry of "colors base" walked into "colors shown",
            # see-through left see-through and every other drawn (Console::PS1Hardware::TEXEL_DRAWN); the
            # backdrop's fill set from the first; and each table copied into video RAM, once the chip has drawn
            # everything sent before, as Paint's rt_paint_upload copies the pictures at power-on.
            def emit_shown(asm, memory, at)
              h = Console::PS1Hardware
              asm.label("rt_colors_shown")
              asm.lw(:t0, at.call(DIRTY), :gp)
              asm.bne(:t0, :zero, "rt_colors_shown_owed")
              asm.jr(:ra)
              asm.label("rt_colors_shown_owed")
              asm.sw(:zero, at.call(DIRTY), :gp)
              asm.addiu(:sp, :sp, -4 * (SHOWN_KEPT.length + 1))
              asm.sw(:ra, 0, :sp)
              SHOWN_KEPT.each_with_index { |register, i| asm.sw(register, 4 + (i * 4), :sp) }
              asm.la(:s0, BASE)
              asm.la(:s1, SHOWN)
              asm.la(:t0, HALFWORDS)
              asm.lw(:s2, 0, :t0)
              asm.label("rt_colors_shown_entry")
              asm.lhu(:a0, 0, :s0)
              asm.beq(:a0, :zero, "rt_colors_shown_store") { asm.move(:v0, :zero) }
              asm.jal("rt_color_walked") { asm.andi(:a0, :a0, 0x7FFF) }
              asm.ori(:v0, :v0, h::TEXEL_DRAWN)
              asm.label("rt_colors_shown_store")
              asm.sh(:v0, 0, :s1)
              asm.addiu(:s0, :s0, 2)
              asm.addiu(:s2, :s2, -1)
              asm.bgtz(:s2, "rt_colors_shown_entry") { asm.addiu(:s1, :s1, 2) }
              emit_backdrop_fill(asm, memory)
              emit_tables_copied(asm)
              asm.lw(:ra, 0, :sp)
              SHOWN_KEPT.each_with_index { |register, i| asm.lw(register, 4 + (i * 4), :sp) }
              asm.jr(:ra) { asm.addiu(:sp, :sp, 4 * (SHOWN_KEPT.length + 1)) }
            end

            # The backdrop's fill command (Tiles::BACKDROP) from the first colour shown: each five-bit channel at
            # the top of its byte (Console::PS1Hardware.command_color).
            def emit_backdrop_fill(asm, memory)
              h = Console::PS1Hardware
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
            end

            # Each table in "colors tables" copied from "colors shown" into video RAM: its command's three words to
            # the port, then its colours by the DMA, in blocks of one word, waiting for each to be sent.
            def emit_tables_copied(asm)
              h = Console::PS1Hardware
              asm.jal("rt_draw_list_finish")
              asm.la(:s0, TABLES)
              asm.lw(:s2, 0, :s0)
              asm.addiu(:s0, :s0, 4)
              asm.la(:s1, SHOWN)
              asm.label("rt_colors_shown_table")
              asm.beq(:s2, :zero, "rt_colors_shown_tables_done")
              asm.jal("rt_gp0_port_word") { asm.lui(:a0, h::GP0_COPY_TO_VRAM >> 16) }
              asm.lui(:t5, h::IO >> 16)
              asm.lw(:t0, 0, :s0)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t5)
              asm.lw(:t0, 4, :s0)
              asm.sw(:t0, h::GP0 & 0xFFFF, :t5)
              asm.lw(:t0, 8, :s0)
              asm.addu(:t0, :t0, :s1)
              asm.sw(:t0, h::DMA2_MADR & 0xFFFF, :t5)
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
