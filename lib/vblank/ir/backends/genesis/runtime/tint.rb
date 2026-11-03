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
          # Nothing is written to the colour memory at once. A change says it is owed (DIRTY), and as the pass
          # ends (rt_colors_prepared, before the wait) every place the game uses is worked out into a copy of the
          # colour memory in work RAM (CRAM; USED says how many places of each palette, and the backdrop is
          # always one) — worked out then because a sum for each of the sixty colours takes longer than the
          # blank does, and a colour written after it is on the screen for a frame. The blank only copies
          # the whole of it (rt_colors_written), so the colours change on the frame the game said, with the
          # sprite table and the scroll. A colour that is not changed is not worked out again.
          #
          #   rt_tint_to(mode, steps, color)         D0 = 1 black, 2 white, 3 the colour in D2; D1 the 256ths
          #   rt_colors_hold(table, which, palette)  a list's other colours, see Runtime::Tiles's tables
          #   rt_backdrop_hold(table, which)         a backdrop that follows a list, its colour in that set
          #   rt_colors_prepared                     as a pass ends: the copy of the colour memory made to say it
          #   rt_colors_written                      the blank's work: the copy written to the colour memory
          module Tint
            MODE = "rt tint" # the fade or tint in force: its mode, its steps, 256 less its steps, and the
            STEPS = 2 #           tint colour's three channels, a word each
            KEEP = 4
            TARGET = 6
            TINT_BYTES = 12
            COLORS = "rt colors" # the game's colours, a word for each of the 64 places of the colour memory
            USED = "rt colors used" # how many places of each palette the game uses, a word each
            DIRTY = "rt colors dirty"
            CRAM = "rt cram" # the colour memory as it is to be, a word for each of its 64 places
            OWED = "rt cram owed" # 1 while CRAM is not yet in the colour memory
            SETS = "rt colors sets" # for each palette, the set of a list it holds now (a long), or nought

            NONE = 0
            TOWARD_BLACK = 1
            TOWARD_WHITE = 2
            TOWARD_COLOR = 3

            module_function

            def reserve(memory)
              memory.reserve(MODE, TINT_BYTES)
              memory.reserve(COLORS, Art::PALETTES * Art::PLACES * 2)
              memory.reserve(USED, Art::PALETTES * 2)
              memory.reserve(DIRTY, 2)
              memory.reserve(CRAM, Art::PALETTES * Art::PLACES * 2)
              memory.reserve(OWED, 2)
              memory.reserve(SETS, Art::PALETTES * 4)
            end

            # +backdrop+ for a game whose backdrop is copied from a list it recolours, which then carries
            # rt_backdrop_hold.
            def emit(asm, memory, backdrop: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_start(asm, memory)
              emit_tint_to(asm, at)
              emit_tinted(asm, at)
              emit_hold(asm, memory, at)
              emit_backdrop_hold(asm, at) if backdrop
              emit_prepared(asm, memory, at)
              emit_written(asm, memory, at)
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
              asm.rts
            end

            # rt_tint_to: the fade or tint in force, from now on. The colour's channels are kept apart.
            def emit_tint_to(asm, at)
              asm.label("rt_tint_to")
              asm.move(:w, asm.d(0), at.call(MODE))
              asm.move(:w, asm.d(1), at.call(MODE, STEPS))
              asm.move(:w, asm.imm(256), asm.d(3))
              asm.sub(:w, asm.d(1), asm.d(3))
              asm.move(:w, asm.d(3), at.call(MODE, KEEP))
              3.times do |channel|
                asm.move(:w, asm.d(2), asm.d(3))
                asm.lsr(:w, 5, asm.d(2)) if channel < 2
                asm.and(:w, asm.imm(31), asm.d(3))
                asm.move(:w, asm.d(3), at.call(MODE, TARGET + (channel * 2)))
              end
              asm.move(:w, asm.imm(1), at.call(DIRTY))
              asm.rts
            end

            # rt_tinted: D0 = a colour of the game's, D0 = the word of the colour memory it is shown as. Each
            # channel in turn is moved as the mode says, cut to three bits and put where the word has it:
            # 0000 BBB0 GGG0 RRR0. It uses D1 to D3 and nothing else.
            def emit_tinted(asm, at)
              asm.label("rt_tinted")
              asm.moveq(0, asm.d(1))
              3.times do |channel|
                done = "rt_tinted_#{channel}"
                asm.moveq(0, asm.d(2))
                asm.move(:w, asm.d(0), asm.d(2))
                asm.and(:w, asm.imm(31), asm.d(2))
                asm.lsr(:w, 5, asm.d(0))
                asm.tst(:w, at.call(MODE))
                asm.branch(:eq, "#{done}_cut")
                asm.cmp(:w, asm.imm(TOWARD_WHITE), at.call(MODE))
                asm.branch(:eq, "#{done}_white")
                asm.branch(:hi, "#{done}_color")
                asm.move(:w, asm.d(2), asm.d(3))
                asm.mulu(at.call(MODE, STEPS), asm.d(3))
                asm.lsr(:l, 8, asm.d(3))
                asm.sub(:w, asm.d(3), asm.d(2))
                asm.bra("#{done}_cut")
                asm.label("#{done}_white")
                asm.moveq(31, asm.d(3))
                asm.sub(:w, asm.d(2), asm.d(3))
                asm.mulu(at.call(MODE, STEPS), asm.d(3))
                asm.lsr(:l, 8, asm.d(3))
                asm.add(:w, asm.d(3), asm.d(2))
                asm.bra("#{done}_cut")
                asm.label("#{done}_color")
                asm.move(:w, at.call(MODE, TARGET + (channel * 2)), asm.d(3))
                asm.mulu(at.call(MODE, STEPS), asm.d(3))
                asm.mulu(at.call(MODE, KEEP), asm.d(2))
                asm.add(:l, asm.d(3), asm.d(2))
                asm.lsr(:l, 8, asm.d(2))
                asm.label("#{done}_cut")
                asm.lsr(:w, 2, asm.d(2))
                asm.moveq(1 + (4 * channel), asm.d(3))
                asm.lsl(:w, asm.d(3), asm.d(2))
                asm.or(:w, asm.d(2), asm.d(1))
              end
              asm.move(:w, asm.d(1), asm.d(0))
              asm.rts
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
              asm.lea(asm.abs_l(memory[COLORS]), asm.a(1))
              asm.lea(asm.abs_l(memory[USED]), asm.a(2))
              asm.move(:w, asm.ind(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_tinted"))
              asm.move(:w, asm.d(0), asm.abs_l(memory[CRAM]))
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
                asm.move(:w, asm.post(1), asm.d(0))
                asm.jsr(asm.abs_l("rt_tinted"))
                asm.move(:w, asm.d(0), asm.post(3))
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
