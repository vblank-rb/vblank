# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE COLOURS A GAME CHANGES AS IT RUNS: a fade, a tint, and a list of sprite colours told to hold
          # other colours (`recolor`). All three are one thing on a Genesis, the colour memory written again, so
          # they are one piece of the runtime.
          #
          # The colour memory holds the colours as the screen shows them, three bits a channel; the game's
          # colours have five. So the cartridge keeps the game's own colours in work RAM (the table COLORS, a
          # word for each place of the colour memory, 5-5-5 as every other console's are), and the colour
          # memory is worked out from it: each colour moved by the fade or tint in force, then cut to the
          # bits the console keeps, as the interpreter cuts a picture it shows. A fade moves the colour the
          # game named and not the cut one, which is why.
          #
          # What moves a colour is Framebuffer#walked_toward (a fade toward black or white) or #mixed (a tint
          # toward a colour), both counted in 256ths (FadeSteps::WALK) in five bits a channel, a channel
          # keeping or taking its share and the fraction dropped:
          #
          #   toward black   c - (c × steps ÷ 256)
          #   toward white   c + ((31 - c) × steps ÷ 256)
          #   toward a tint  (c × (256 - steps) + tint × steps) ÷ 256
          #
          # All three are one sum, (c × keep + add) ÷ 256, with keep = 256 - steps and an add for each channel
          # that does not hang on c: 255 toward black (c less a share rounded down is the share kept rounded
          # up), 31 × steps toward white, and the tint's channel × steps toward a colour. No steps is keep 256,
          # which leaves c as it is whatever the add. So a walk is worked out once for each of the 32 values
          # a channel can hold (rt_tint_tables), into a table for each channel already cut to three bits and
          # put where the colour memory's word has that channel, and each colour is then three words read
          # from those tables and put together. A sum is walked from one value to the next by adding keep, so
          # the tables take no multiply at all. That is the shape of a Genesis game's own fade: work once a
          # step what each colour needs, rather than three multiplies for each colour on every pass.
          #
          # Nothing is written to the colour memory at once. A change marks it as owed (DIRTY), and as the pass
          # ends (rt_colors_prepared, before the wait) every place the game uses is worked out into a copy of the
          # colour memory in work RAM (CRAM; USED holds how many places of each palette, and the backdrop is
          # always one) — worked out then because the sixty colours take longer than the blank does, and a
          # colour written after it is on the screen for a frame. The blank only copies the whole of it
          # (rt_colors_written), so the colours change on the frame the game set them, with the sprite table
          # and the scroll. A colour that is not changed is not worked out again, and the tables are worked
          # out again only when the walk changes (TABLES_OWED), not when a list changes its colours.
          #
          #   rt_tint_to(mode, steps, color)         D0 = 0 black, 1 white, 2 the colour in D2; D1 the 256ths
          #   rt_colors_hold(table, which, palette)  a list's other colours, see Runtime::Tiles's tables
          #   rt_backdrop_hold(table, which)         a backdrop that follows a list, its colour in that set
          #   rt_scene_colors(table)                 a scene taking over: its own palettes
          #   rt_colors_prepared                     as a pass ends: the copy of the colour memory made to hold it
          #   rt_colors_written                      the blank's work: the copy written to the colour memory
          module Tint
            MODE = "rt tint" # The fade or tint in force: its mode, its steps, each channel's add, and the
            STEPS = 2 #           colour as it was handed over, a word each
            ADD = 4
            COLOR = 10
            TINT_BYTES = 12
            TABLES = "rt tint tables" # For each channel, the word of the colour memory each of its 32 values is shown as
            TABLE_BYTES = 32 * 2
            TABLES_OWED = "rt tint tables owed" # 1 while TABLES are not yet worked out for the walk in force
            COLORS = "rt colors" # The game's colours, a word for each of the 64 places of the colour memory
            USED = "rt colors used" # How many places of each palette the game uses, a word each
            DIRTY = "rt colors dirty"
            CRAM = "rt cram" # The colour memory as it is to be, a word for each of its 64 places
            OWED = "rt cram owed" # 1 while CRAM is not yet in the colour memory
            SETS = "rt colors sets" # For each palette, the set of a list it holds now (a long), or nought

            TOWARD_BLACK = PaletteWalk::TOWARD_BLACK
            TOWARD_WHITE = PaletteWalk::TOWARD_WHITE
            TOWARD_COLOR = PaletteWalk::TOWARD_COLOR

            module_function

            def reserve(memory)
              memory.reserve(MODE, TINT_BYTES)
              memory.reserve(TABLES, 3 * TABLE_BYTES)
              memory.reserve(TABLES_OWED, 2)
              memory.reserve(COLORS, Art::PALETTES * Art::PLACES * 2)
              memory.reserve(USED, Art::PALETTES * 2)
              memory.reserve(DIRTY, 2)
              memory.reserve(CRAM, Art::PALETTES * Art::PLACES * 2)
              memory.reserve(OWED, 2)
              memory.reserve(SETS, Art::PALETTES * 4)
            end

            # +backdrop+ for a game whose backdrop is copied from a list it recolours, which then carries
            # rt_backdrop_hold; +scene_colors+ for one whose scenes each write their own palettes, which
            # carries rt_scene_colors.
            def emit(asm, memory, backdrop: false, scene_colors: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm, memory)
              emit_tint_to(asm, at)
              emit_tint_tables(asm, memory, at)
              emit_hold(asm, memory, at)
              emit_backdrop_hold(asm, at) if backdrop
              emit_scene_colors(asm, memory, at) if scene_colors
              emit_prepared(asm, memory, at)
              emit_written(asm, memory, at)
            end

            # rt_scene_colors(table): a scene taking over writes its own palettes into the game's colours
            # (Lowering::Picture#emit_scene_colors). The table is a word, how many palettes, then for each its
            # number, how many of its places hold a colour, and its fifteen colours, a word each. DIRTY is set,
            # so the colour memory is worked out again as the pass ends, through the fade or tint in force.
            def emit_scene_colors(asm, memory, at)
              asm.label("rt_scene_colors")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:w, asm.post(0), asm.d(1))
              asm.branch(:eq, "rt_scene_colors_done")
              asm.subq(:w, 1, asm.d(1))
              asm.label("rt_scene_colors_palette")
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.post(0), asm.d(2))
              asm.add(:l, asm.d(2), asm.d(2)) # a palette's count of places is a word
              asm.lea(asm.abs_l(memory[USED]), asm.a(1))
              asm.move(:w, asm.post(0), asm.idx(1, 0, 2))
              asm.lsl(:l, 4, asm.d(2)) # two bytes a palette became thirty-two: a palette's places in the colours
              asm.lea(asm.abs_l(memory[COLORS], 2), asm.a(1))
              asm.add(:l, asm.d(2), asm.a(1))
              asm.moveq(Art::OWN_COLORS - 1, asm.d(3))
              asm.label("rt_scene_colors_place")
              asm.move(:w, asm.post(0), asm.post(1))
              asm.dbra(asm.d(3), "rt_scene_colors_place")
              asm.dbra(asm.d(1), "rt_scene_colors_palette")
              asm.move(:w, asm.imm(1), at.call(DIRTY))
              asm.label("rt_scene_colors_done")
              asm.rts
            end

            # rt_backdrop_hold(table, which): the backdrop follows a list of colours, and is the colour the
            # table gives for set +which+. The table is a word, how many sets there are besides the colours
            # the list was declared with, then the backdrop's colour in that set and in each of the others, a
            # word each: so a number naming none is the declared one, as rt_colors_hold counts them. The colour
            # goes into colour 0, the backdrop, in the game's colours, and the colour memory is owed. A colour
            # the backdrop holds already costs nothing, which keeps a list told the same set every pass from
            # working all sixty colours out again.
            def emit_backdrop_hold(asm, at)
              asm.label("rt_backdrop_hold")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.post(0), asm.d(3))
              asm.cmp(:l, asm.d(3), asm.d(1))
              asm.branch(:cc, "rt_backdrop_hold_own")
              asm.addq(:l, 1, asm.d(1))
              asm.bra("rt_backdrop_hold_set")
              asm.label("rt_backdrop_hold_own")
              asm.moveq(0, asm.d(1))
              asm.label("rt_backdrop_hold_set")
              asm.add(:l, asm.d(1), asm.d(1)) # a colour is a word
              asm.add(:l, asm.d(1), asm.a(0))
              asm.move(:w, asm.ind(0), asm.d(0))
              asm.cmp(:w, at.call(COLORS), asm.d(0))
              asm.branch(:eq, "rt_backdrop_hold_done")
              asm.move(:w, asm.d(0), at.call(COLORS))
              asm.move(:w, asm.imm(1), at.call(DIRTY))
              asm.label("rt_backdrop_hold_done")
              asm.rts
            end

            # rt_colors_start: the game's colours (the table "colors15": the 64 places' colours, then how many
            # places of each palette are used) into work RAM. A0 is not asked for: the table is one of the
            # picture's, whichever kind of picture it is.
            def emit_start(asm, memory)
              asm.label("rt_colors_start")
              asm.lea(asm.abs_l("colors15"), asm.a(0))
              asm.lea(asm.abs_l(memory[COLORS]), asm.a(1))
              asm.move(:w, asm.imm((Art::PALETTES * Art::PLACES) - 1), asm.d(0))
              asm.label("rt_colors_start_color")
              asm.move(:w, asm.post(0), asm.post(1))
              asm.dbra(asm.d(0), "rt_colors_start_color")
              asm.lea(asm.abs_l(memory[USED]), asm.a(1))
              asm.moveq(Art::PALETTES - 1, asm.d(0))
              asm.label("rt_colors_start_used")
              asm.move(:w, asm.post(0), asm.post(1))
              asm.dbra(asm.d(0), "rt_colors_start_used")
              asm.move(:w, asm.imm(1), asm.disp(5, memory.displacement(DIRTY)))
              asm.move(:w, asm.imm(1), asm.disp(5, memory.displacement(TABLES_OWED)))
              asm.rts
            end

            # rt_tint_to: the fade or tint in force, from now on. The colour's channels are kept apart.
            # Set the same as the one in force, it does nothing, so a game that sets its tint every
            # pass works its colours out only on the passes it changes (PaletteWalk). No steps at all is
            # the colours as they are, whatever they were walked toward. A change works out each channel's
            # add (see the top of this module) and owes the tables.
            def emit_tint_to(asm, at)
              asm.label("rt_tint_to")
              asm.cmp(:w, at.call(MODE, STEPS), asm.d(1))
              asm.branch(:ne, "rt_tint_to_changed")
              asm.tst(:w, asm.d(1))
              asm.branch(:eq, "rt_tint_to_same")
              asm.cmp(:w, at.call(MODE), asm.d(0))
              asm.branch(:ne, "rt_tint_to_changed")
              asm.cmp(:w, at.call(MODE, COLOR), asm.d(2))
              asm.branch(:ne, "rt_tint_to_changed")
              asm.label("rt_tint_to_same")
              asm.rts
              asm.label("rt_tint_to_changed")
              asm.move(:w, asm.d(2), at.call(MODE, COLOR))
              asm.move(:w, asm.d(0), at.call(MODE))
              asm.move(:w, asm.d(1), at.call(MODE, STEPS))
              asm.cmp(:w, asm.imm(TOWARD_WHITE), asm.d(0))
              asm.branch(:eq, "rt_tint_to_white")
              asm.branch(:hi, "rt_tint_to_color")
              3.times { |channel| asm.move(:w, asm.imm(255), at.call(MODE, ADD + (channel * 2))) }
              asm.bra("rt_tint_to_owed")
              asm.label("rt_tint_to_white")
              asm.mulu(asm.imm(31), asm.d(1))
              3.times { |channel| asm.move(:w, asm.d(1), at.call(MODE, ADD + (channel * 2))) }
              asm.bra("rt_tint_to_owed")
              asm.label("rt_tint_to_color")
              3.times do |channel|
                asm.move(:w, asm.d(2), asm.d(3))
                asm.lsr(:w, 5, asm.d(2)) if channel < 2
                asm.and(:w, asm.imm(31), asm.d(3))
                asm.mulu(asm.d(1), asm.d(3))
                asm.move(:w, asm.d(3), at.call(MODE, ADD + (channel * 2)))
              end
              asm.label("rt_tint_to_owed")
              asm.move(:w, asm.imm(1), at.call(TABLES_OWED))
              asm.move(:w, asm.imm(1), at.call(DIRTY))
              asm.rts
            end

            # rt_tint_tables: TABLES worked out for the walk in force, each channel's sum walked over its 32
            # values by adding keep. Uses D0 to D4, D7 and A0. A sum (c × keep + add) is under 2^13 and its
            # top three bits are the channel's three, so each is cut and put in its place in the colour
            # memory's word, 0000 BBB0 GGG0 RRR0, by a shift and a mask:
            #
            #   red    (sum >> 9) & 0x00E     green  (sum >> 5) & 0x0E0     blue  (sum & 0x1C00) >> 1
            def emit_tint_tables(asm, memory, at)
              asm.label("rt_tint_tables")
              asm.clr(:w, at.call(TABLES_OWED))
              asm.move(:w, asm.imm(FadeSteps::WALK), asm.d(4))
              asm.sub(:w, at.call(MODE, STEPS), asm.d(4))
              asm.move(:w, at.call(MODE, ADD), asm.d(1))
              asm.move(:w, at.call(MODE, ADD + 2), asm.d(2))
              asm.move(:w, at.call(MODE, ADD + 4), asm.d(3))
              asm.lea(asm.abs_l(memory[TABLES]), asm.a(0))
              asm.moveq(31, asm.d(7))
              asm.label("rt_tint_tables_value")
              asm.move(:w, asm.d(1), asm.d(0))
              asm.lsr(:w, 8, asm.d(0))
              asm.lsr(:w, 1, asm.d(0))
              asm.and(:w, asm.imm(0x00E), asm.d(0))
              asm.move(:w, asm.d(0), asm.ind(0))
              asm.move(:w, asm.d(2), asm.d(0))
              asm.lsr(:w, 5, asm.d(0))
              asm.and(:w, asm.imm(0x0E0), asm.d(0))
              asm.move(:w, asm.d(0), asm.disp(0, TABLE_BYTES))
              asm.move(:w, asm.d(3), asm.d(0))
              asm.and(:w, asm.imm(0x1C00), asm.d(0))
              asm.lsr(:w, 1, asm.d(0))
              asm.move(:w, asm.d(0), asm.disp(0, 2 * TABLE_BYTES))
              asm.addq(:l, 2, asm.a(0))
              asm.add(:w, asm.d(4), asm.d(1))
              asm.add(:w, asm.d(4), asm.d(2))
              asm.add(:w, asm.d(4), asm.d(3))
              asm.dbra(asm.d(7), "rt_tint_tables_value")
              asm.rts
            end

            # One colour of the game's from A1 (moved on) shown as the colour memory's word, into D1: each
            # channel's word read from its table. A0 holds the middle table, green's, since an index reaches
            # only a byte either way, and D5 the mask 62, which keeps a channel counted in words. Uses D0
            # and D2.
            def emit_color_lookup(asm)
              asm.move(:w, asm.post(1), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.d(5), asm.d(2))
              asm.move(:w, asm.idx(0, -TABLE_BYTES, 2, :w), asm.d(1))
              asm.lsr(:w, 5, asm.d(0))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.d(5), asm.d(2))
              asm.or(:w, asm.idx(0, 0, 2, :w), asm.d(1))
              asm.lsr(:w, 5, asm.d(0))
              asm.and(:w, asm.d(5), asm.d(0))
              asm.or(:w, asm.idx(0, TABLE_BYTES, 0, :w), asm.d(1))
            end

            # rt_colors_hold: a list holds another set of colours. +table+ is a word, how many sets there are
            # besides the colours the list was declared with, then that set and each of the others, SET_BYTES
            # each; +which+ names one of the others, and a number naming none is the declared colours, as the
            # interpreter holds them (Reference#colors_held_by). The set's colours go into the palette's places
            # in the game's colours, and the colour memory is owed. A set a palette holds already costs nothing.
            def emit_hold(asm, memory, at)
              asm.label("rt_colors_hold")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.post(0), asm.d(3))
              asm.cmp(:l, asm.d(3), asm.d(1))
              asm.branch(:cc, "rt_colors_hold_own")
              asm.addq(:l, 1, asm.d(1))
              asm.bra("rt_colors_hold_set")
              asm.label("rt_colors_hold_own")
              asm.moveq(0, asm.d(1))
              asm.label("rt_colors_hold_set")
              asm.mulu(asm.imm(Tiles::SET_BYTES), asm.d(1))
              asm.add(:l, asm.d(1), asm.a(0))
              asm.move(:l, asm.a(0), asm.d(1))
              asm.lsl(:l, 2, asm.d(2))
              asm.lea(asm.abs_l(memory[SETS]), asm.a(1))
              asm.cmp(:l, asm.idx(1, 0, 2), asm.d(1))
              asm.branch(:eq, "rt_colors_hold_done")
              asm.move(:l, asm.d(1), asm.idx(1, 0, 2))
              asm.lsl(:l, 3, asm.d(2)) # four bytes a palette became thirty-two: a palette's places in the colours
              asm.lea(asm.abs_l(memory[COLORS], 2), asm.a(1))
              asm.add(:l, asm.d(2), asm.a(1))
              asm.moveq(Art::OWN_COLORS - 1, asm.d(3))
              asm.label("rt_colors_hold_place")
              asm.move(:w, asm.post(0), asm.post(1))
              asm.dbra(asm.d(3), "rt_colors_hold_place")
              asm.move(:w, asm.imm(1), at.call(DIRTY))
              asm.label("rt_colors_hold_done")
              asm.rts
            end

            # rt_colors_prepared, as a pass ends: if the colours are owed, the backdrop and then each palette's
            # used places are worked out into CRAM, every other place nothing, and CRAM is owed to the colour
            # memory.
            def emit_prepared(asm, memory, at)
              asm.label("rt_colors_prepared")
              asm.tst(:w, at.call(DIRTY))
              asm.branch(:ne, "rt_colors_prepared_owed")
              asm.rts
              asm.label("rt_colors_prepared_owed")
              asm.clr(:w, at.call(DIRTY))
              asm.move(:w, asm.imm(1), at.call(OWED))
              asm.lea(asm.abs_l(memory[CRAM]), asm.a(3))
              asm.moveq((Art::PALETTES * Art::PLACES / 2) - 1, asm.d(7))
              asm.label("rt_colors_prepared_clear")
              asm.clr(:l, asm.post(3))
              asm.dbra(asm.d(7), "rt_colors_prepared_clear")
              asm.tst(:w, at.call(TABLES_OWED))
              asm.branch(:eq, "rt_colors_prepared_tables")
              asm.jsr(asm.abs_l("rt_tint_tables"))
              asm.label("rt_colors_prepared_tables")
              asm.lea(asm.abs_l(memory[TABLES], TABLE_BYTES), asm.a(0))
              asm.moveq(62, asm.d(5))
              asm.lea(asm.abs_l(memory[COLORS]), asm.a(1))
              asm.lea(asm.abs_l(memory[USED]), asm.a(2))
              emit_color_lookup(asm)
              asm.move(:w, asm.d(1), asm.abs_l(memory[CRAM]))
              Art::PALETTES.times do |palette|
                skip = "rt_colors_prepared_palette_#{palette}"
                first = ((palette * Art::PLACES) + 1) * 2
                asm.moveq(0, asm.d(7))
                asm.move(:w, asm.post(2), asm.d(7))
                asm.branch(:eq, skip)
                asm.lea(asm.abs_l(memory[COLORS], first), asm.a(1))
                asm.lea(asm.abs_l(memory[CRAM], first), asm.a(3))
                asm.subq(:w, 1, asm.d(7))
                asm.label("#{skip}_place")
                emit_color_lookup(asm)
                asm.move(:w, asm.d(1), asm.post(3))
                asm.dbra(asm.d(7), "#{skip}_place")
                asm.label(skip)
              end
              asm.rts
            end

            # rt_colors_written, in the blank: CRAM, if it is owed, written whole to the colour memory.
            def emit_written(asm, memory, at)
              h = Console::GenesisHardware
              asm.label("rt_colors_written")
              asm.tst(:w, at.call(OWED))
              asm.branch(:ne, "rt_colors_written_owed")
              asm.rts
              asm.label("rt_colors_written_owed")
              asm.clr(:w, at.call(OWED))
              asm.lea(asm.abs_l(memory[CRAM]), asm.a(1))
              asm.move(:l, asm.imm(h.command(h::WRITE_CRAM, 0)), asm.abs_l(h::VDP_CONTROL))
              asm.moveq((Art::PALETTES * Art::PLACES / 2) - 1, asm.d(7))
              asm.label("rt_colors_written_word")
              asm.move(:l, asm.post(1), asm.abs_l(h::VDP_DATA))
              asm.dbra(asm.d(7), "rt_colors_written_word")
              asm.rts
            end
          end
        end
      end
    end
  end
end
