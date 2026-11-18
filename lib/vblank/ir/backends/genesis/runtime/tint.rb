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
          # step what each colour needs, rather than three multiplies for each colour on every pass. Each
          # colour's channels are taken apart once when the game sets it (SPLIT), not on each step of a fade.
          #
          # Nothing is written to the colour memory at once. A change marks the palette lines it touched as owed
          # (DIRTY, a bit for each of the four lines), and as the pass ends (rt_colors_prepared, before the wait)
          # every place the game uses in a marked line is worked out into a copy of the colour memory in work RAM
          # (CRAM; USED holds how many places of each palette, and the backdrop is always one) — worked out then
          # because the sixty colours take longer than the blank does, and a colour written after it is on the
          # screen for a frame. The blank only copies the lines worked out (rt_colors_written, OWED a bit a line
          # as DIRTY is), so the colours change on the frame the game set them, with the sprite table and the
          # scroll. The video chip takes a write to its colour memory at any address, a line at a time as
          # well as all 128 bytes (Sega's Genesis Software Manual, the VDP's CRAM write), so a list told
          # other colours costs its own line and no other: on a pass that changes nothing, nothing is worked
          # out and nothing copied. A fade or tint changes every colour, so it marks all four lines; the tables
          # are worked out again only when the walk changes (TABLES_OWED), not when a list changes its colours.
          #
          #   rt_tint_to(mode, steps, color)         D0 = 0 black, 1 white, 2 the colour in D2; D1 the 256ths
          #   rt_colors_hold(table, which, palette)  a list's other colours, see Runtime::Tiles's tables
          #   rt_colors_hold_places(table, which, first, count)  the same for a list sharing its palette
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
            DIRTY = "rt colors dirty" # A byte: bit n set while palette line n of CRAM is not yet worked out
            CRAM = "rt cram" # The colour memory as it is to be, a word for each of its 64 places
            OWED = "rt cram owed" # A byte: bit n set while line n of CRAM is not yet in the colour memory
            CHANGED = "rt colors changed" # A byte: bit n set while line n's colours are changed since SPLIT noted them
            SPLIT = "rt colors split" # Each place's colour as its channels, three bytes, each counted in words
            ALL_LINES = 0b1111 # DIRTY, CHANGED or OWED with each of the four lines (Art::PALETTES) marked
            SETS = "rt colors sets" # For each place, the set of the list starting after it holds now (a long), or nought

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
              memory.reserve(CHANGED, 2)
              memory.reserve(SPLIT, Art::PALETTES * Art::PLACES * 3)
              memory.reserve(SETS, Art::PALETTES * Art::PLACES * 4)
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
            # number, how many of its places hold a colour, and its fifteen colours, a word each. Each palette
            # written is marked in DIRTY, so it is worked out again as the pass ends, through the fade or tint
            # in force.
            def emit_scene_colors(asm, memory, at)
              asm.label("rt_scene_colors")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.move(:w, asm.post(0), asm.d(1))
              asm.branch(:eq, "rt_scene_colors_done")
              asm.subq(:w, 1, asm.d(1))
              asm.label("rt_scene_colors_palette")
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.post(0), asm.d(2))
              asm.bset(asm.d(2), at.call(DIRTY))
              asm.bset(asm.d(2), at.call(CHANGED))
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
              asm.label("rt_scene_colors_done")
              asm.rts
            end

            # rt_backdrop_hold(table, which): the backdrop follows a list of colours, and is the colour the
            # table gives for set +which+. The table is a word, how many sets there are besides the colours
            # the list was declared with, then the backdrop's colour in that set and in each of the others, a
            # word each: so a number naming none is the declared one, as rt_colors_hold counts them. The colour
            # goes into colour 0, the backdrop, in the game's colours, and palette line 0 is owed. A colour
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
              asm.bset(0, at.call(DIRTY))
              asm.bset(0, at.call(CHANGED))
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
              asm.move(:b, asm.imm(ALL_LINES), asm.disp(5, memory.displacement(DIRTY)))
              asm.move(:b, asm.imm(ALL_LINES), asm.disp(5, memory.displacement(CHANGED)))
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
              asm.move(:b, asm.imm(ALL_LINES), at.call(DIRTY))
              asm.rts
            end

            # rt_tint_tables: TABLES worked out for the walk in force, each channel's sum walked over its 32
            # values by adding keep. Uses D0 to D7 and A0. A sum (c × keep + add) is under 2^13 and its top
            # three bits are the channel's three, which go in their place in the colour memory's word,
            # 0000 BBB0 GGG0 RRR0:
            #
            #   red    (sum >> 9) & 0x00E     green  (sum >> 5) & 0x0E0     blue  (sum >> 1) & 0xE00
            #
            # A shift right by nine is two of the 68000's shifts, each paid for by the bit, so each channel's
            # sum is kept as a long shifted LEFT instead (by 7, 11 and 15, under 2^28): its top half is then
            # the sum shifted right by 9, 5 and 1, and SWAP, one short instruction, brings it down. Keep is
            # shifted the same, so one add a channel walks the sum on.
            #
            # Toward black or white every channel's add is the same, so the three sums are one: the three
            # bits are the same for a value whichever channel holds it, and green's word is red's moved up
            # four bits and blue's eight. And keep is at most 256, so from one value to the next the sum
            # crosses at most one multiple of 1024, where the three bits go up by one. So one sum is walked
            # against the next multiple, and each value is three words stored and a compare; the words
            # change only where the sum crosses, eight times at most in the 32.
            CHANNEL_SHIFTS = [7, 11, 15].freeze # Left, so the top half of each channel's long is its word
            CHANNEL_MASKS = [0x00E, 0x0E0, 0xE00].freeze

            def emit_tint_tables(asm, memory, at)
              sums = [1, 2, 3]
              keeps = [4, 5, 6]
              asm.label("rt_tint_tables")
              asm.clr(:w, at.call(TABLES_OWED))
              asm.move(:l, asm.imm(FadeSteps::WALK), asm.d(0))
              asm.sub(:w, at.call(MODE, STEPS), asm.d(0))
              asm.lea(asm.abs_l(memory[TABLES]), asm.a(0))
              asm.moveq(31, asm.d(7))
              asm.cmp(:w, asm.imm(TOWARD_COLOR), at.call(MODE))
              asm.branch(:eq, "rt_tint_tables_channels")
              emit_one_sum_tables(asm, at)
              asm.label("rt_tint_tables_channels")
              CHANNEL_SHIFTS.each_with_index do |shift, channel|
                asm.moveq(0, asm.d(sums[channel]))
                asm.move(:w, at.call(MODE, ADD + (channel * 2)), asm.d(sums[channel]))
                asm.move(:l, asm.d(0), asm.d(keeps[channel]))
                [sums[channel], keeps[channel]].each { |register| emit_long_shifted_left(asm, register, shift) }
              end
              asm.label("rt_tint_tables_value")
              CHANNEL_MASKS.each_with_index do |mask, channel|
                asm.move(:l, asm.d(sums[channel]), asm.d(0))
                asm.swap(asm.d(0))
                asm.and(:w, asm.imm(mask), asm.d(0))
                asm.move(:w, asm.d(0), channel.zero? ? asm.ind(0) : asm.disp(0, channel * TABLE_BYTES))
              end
              asm.addq(:l, 2, asm.a(0))
              3.times { |channel| asm.add(:l, asm.d(keeps[channel]), asm.d(sums[channel])) }
              asm.dbra(asm.d(7), "rt_tint_tables_value")
              asm.rts
            end

            # The tables toward black or white, from red's sum alone (see above): D0 holds keep, A0 the
            # tables and D7 31. Returns from rt_tint_tables.
            # D5 the sum, D6 the next multiple of 1024 it reaches, D1 to D3 red's, green's and blue's word
            # for the three bits now, D4 keep.
            def emit_one_sum_tables(asm, at)
              asm.move(:w, asm.d(0), asm.d(4))
              asm.move(:w, at.call(MODE, ADD), asm.d(5))
              asm.move(:w, asm.d(5), asm.d(1))
              asm.lsr(:w, 8, asm.d(1))
              asm.lsr(:w, 2, asm.d(1)) # the three bits of the first sum
              asm.move(:w, asm.d(1), asm.d(6))
              asm.addq(:w, 1, asm.d(6))
              asm.lsl(:w, 8, asm.d(6))
              asm.lsl(:w, 2, asm.d(6))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.move(:w, asm.d(1), asm.d(2))
              asm.lsl(:w, 4, asm.d(2))
              asm.move(:w, asm.d(2), asm.d(3))
              asm.lsl(:w, 4, asm.d(3))
              asm.label("rt_tint_tables_one_sum")
              asm.move(:w, asm.d(1), asm.post(0))
              asm.move(:w, asm.d(2), asm.disp(0, TABLE_BYTES - 2))
              asm.move(:w, asm.d(3), asm.disp(0, (2 * TABLE_BYTES) - 2))
              asm.add(:w, asm.d(4), asm.d(5))
              asm.cmp(:w, asm.d(6), asm.d(5))
              asm.branch(:cs, "rt_tint_tables_one_sum_same")
              asm.addq(:w, 2, asm.d(1))
              asm.add(:w, asm.imm(0x020), asm.d(2))
              asm.add(:w, asm.imm(0x200), asm.d(3))
              asm.add(:w, asm.imm(1024), asm.d(6))
              asm.label("rt_tint_tables_one_sum_same")
              asm.dbra(asm.d(7), "rt_tint_tables_one_sum")
              asm.rts
            end

            # A long in D+register+ shifted left by +count+, in the 68000's shifts of 1 to 8.
            def emit_long_shifted_left(asm, register, count)
              while count.positive?
                asm.lsl(:l, [count, 8].min, asm.d(register))
                count -= 8
              end
            end

            # One colour of the game's from A1 (moved on) shown as the colour memory's word, into D1: each
            # channel, counted in words, read from its table. With +noted+, each channel is also stored as a
            # byte at A2 (moved on) for the walks after. A0 holds the middle table, green's, since an index
            # reaches only a byte either way, and D5 the mask 62. Uses D0 and D2.
            def emit_color_split_and_looked_up(asm, noted:)
              asm.move(:w, asm.post(1), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.d(5), asm.d(2))
              asm.move(:b, asm.d(2), asm.post(2)) if noted
              asm.move(:w, asm.idx(0, -TABLE_BYTES, 2, :w), asm.d(1))
              asm.lsr(:w, 5, asm.d(0))
              asm.move(:w, asm.d(0), asm.d(2))
              asm.and(:w, asm.d(5), asm.d(2))
              asm.move(:b, asm.d(2), asm.post(2)) if noted
              asm.or(:w, asm.idx(0, 0, 2, :w), asm.d(1))
              asm.lsr(:w, 5, asm.d(0))
              asm.and(:w, asm.d(5), asm.d(0))
              asm.move(:b, asm.d(0), asm.post(2)) if noted
              asm.or(:w, asm.idx(0, TABLE_BYTES, 0, :w), asm.d(1))
            end

            # One colour shown as the colour memory's word, into D1, from its channels as
            # #emit_color_split_and_looked_up noted them at A2 (moved on): three bytes read, three words
            # read from the tables, no shift. D0's top byte must be nought, since a byte read keeps it.
            def emit_split_color_looked_up(asm)
              asm.move(:b, asm.post(2), asm.d(0))
              asm.move(:w, asm.idx(0, -TABLE_BYTES, 0, :w), asm.d(1))
              asm.move(:b, asm.post(2), asm.d(0))
              asm.or(:w, asm.idx(0, 0, 0, :w), asm.d(1))
              asm.move(:b, asm.post(2), asm.d(0))
              asm.or(:w, asm.idx(0, TABLE_BYTES, 0, :w), asm.d(1))
            end

            # rt_colors_hold: a list holds another set of colours. +table+ is a word, how many sets there are
            # besides the colours the list was declared with, then that set and each of the others, SET_BYTES
            # each; +which+ names one of the others, and a number naming none is the declared colours, as the
            # interpreter holds them (Reference#colors_held_by). The set's colours go into the palette's places
            # in the game's colours, and that palette's line is owed. A set a palette holds already costs nothing.
            #
            # rt_colors_hold_places(table, which, first, count) is the same for a list that shares its palette
            # with other lists (Art#share_held_palette): +first+ is the place before the list's first, counted
            # over the whole colour memory (a palette is sixteen), and +count+ is one less than how many places
            # it has, so the set goes into its own places alone. SETS notes the set at +first+, so each list
            # in a palette is noted apart; rt_colors_hold is the palette's first place and all fifteen.
            def emit_hold(asm, memory, at)
              asm.label("rt_colors_hold")
              asm.lsl(:l, 4, asm.d(2)) # a palette is sixteen places
              asm.moveq(Art::OWN_COLORS - 1, asm.d(3))
              asm.label("rt_colors_hold_places")
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.moveq(0, asm.d(4))
              asm.move(:w, asm.post(0), asm.d(4))
              asm.cmp(:l, asm.d(4), asm.d(1))
              asm.branch(:cc, "rt_colors_hold_own")
              asm.addq(:l, 1, asm.d(1))
              asm.bra("rt_colors_hold_set")
              asm.label("rt_colors_hold_own")
              asm.moveq(0, asm.d(1))
              asm.label("rt_colors_hold_set")
              asm.mulu(asm.imm(Tiles::SET_BYTES), asm.d(1))
              asm.add(:l, asm.d(1), asm.a(0))
              asm.move(:l, asm.a(0), asm.d(1))
              asm.lsl(:l, 2, asm.d(2)) # a place's note is a long
              asm.lea(asm.abs_l(memory[SETS]), asm.a(1))
              asm.cmp(:l, asm.idx(1, 0, 2), asm.d(1))
              asm.branch(:eq, "rt_colors_hold_done")
              asm.move(:l, asm.d(1), asm.idx(1, 0, 2))
              asm.lsr(:l, 1, asm.d(2)) # and its colour a word
              asm.lea(asm.abs_l(memory[COLORS], 2), asm.a(1))
              asm.add(:l, asm.d(2), asm.a(1))
              asm.label("rt_colors_hold_place")
              asm.move(:w, asm.post(0), asm.post(1))
              asm.dbra(asm.d(3), "rt_colors_hold_place")
              asm.lsr(:l, 5, asm.d(2)) # a place's colour, counted in bytes, to its palette: sixteen words a line
              asm.bset(asm.d(2), at.call(DIRTY))
              asm.bset(asm.d(2), at.call(CHANGED))
              asm.label("rt_colors_hold_done")
              asm.rts
            end

            # rt_colors_prepared, as a pass ends: each line DIRTY marks is worked out into CRAM, its used places
            # through the walk in force and the rest of its places nothing (the backdrop, place 0 of line 0, is
            # always used), and owed to the colour memory. A pass that marked no line costs a test.
            #
            # A line whose colours the game changed (CHANGED) has each colour taken apart into its channels as
            # it is worked out; a line only the walk moved, a fade's every pass, reads its channels back from
            # where they were noted (SPLIT), which leaves three reads from the tables a colour and no shift.
            # The 68000 shifts a bit at a time, so the two shifts that take a colour apart are as long as the
            # rest of its work. The channels are noted only while a walk is in force: a game that changes its
            # colours with no fade or tint pays nothing for the note, and its lines stay CHANGED until a walk
            # first moves them.
            def emit_prepared(asm, memory, at)
              asm.label("rt_colors_prepared")
              asm.tst(:b, at.call(DIRTY))
              asm.branch(:ne, "rt_colors_prepared_owed")
              asm.rts
              asm.label("rt_colors_prepared_owed")
              asm.tst(:w, at.call(TABLES_OWED))
              asm.branch(:eq, "rt_colors_prepared_tables")
              asm.jsr(asm.abs_l("rt_tint_tables"))
              asm.label("rt_colors_prepared_tables")
              asm.move(:b, at.call(DIRTY), asm.d(6))
              asm.move(:b, at.call(CHANGED), asm.d(3))
              asm.clr(:b, at.call(DIRTY))
              asm.tst(:w, at.call(MODE, STEPS))
              asm.branch(:eq, "rt_colors_prepared_unwalked")
              asm.clr(:b, at.call(CHANGED))
              asm.label("rt_colors_prepared_unwalked")
              asm.or(:b, asm.d(6), at.call(OWED))
              asm.lea(asm.abs_l(memory[TABLES], TABLE_BYTES), asm.a(0))
              asm.moveq(62, asm.d(5))
              Art::PALETTES.times { |palette| emit_line_prepared(asm, memory, at, palette) }
              asm.rts
            end

            # Palette line +palette+ worked out into CRAM if D6 marks it, its colours taken apart again if D3
            # marks it. A0 and D5 are set for the lookups; D0 to D2, D4, D7 and A1 to A3 are used. The backdrop
            # is place 0 of line 0 and is worked out with the line's colours; place 0 of any other line is
            # see-through and never shown.
            def emit_line_prepared(asm, memory, at, palette)
              skip = "rt_colors_prepared_palette_#{palette}"
              first = palette.zero? ? 0 : (palette * Art::PLACES) + 1
              asm.btst(palette, asm.d(6))
              asm.branch(:eq, skip)
              asm.clr(:w, asm.abs_l(memory[CRAM], palette * Art::PLACES * 2)) unless palette.zero?
              asm.lea(asm.abs_l(memory[COLORS], first * 2), asm.a(1))
              asm.lea(asm.abs_l(memory[SPLIT], first * 3), asm.a(2))
              asm.lea(asm.abs_l(memory[CRAM], first * 2), asm.a(3))
              asm.moveq(0, asm.d(7))
              asm.move(:w, at.call(USED, palette * 2), asm.d(7))
              asm.moveq(Art::OWN_COLORS, asm.d(4))
              asm.sub(:w, asm.d(7), asm.d(4))
              # Line 0 counts the backdrop too, one more than its used places, so its count less one is USED.
              unless palette.zero?
                asm.subq(:w, 1, asm.d(7))
                asm.branch(:mi, "#{skip}_unused")
              end
              asm.btst(palette, asm.d(3))
              asm.branch(:eq, "#{skip}_walked")
              asm.tst(:w, at.call(MODE, STEPS))
              asm.branch(:eq, "#{skip}_unwalked")
              emit_places_prepared(asm, "#{skip}_place") { emit_color_split_and_looked_up(asm, noted: true) }
              asm.bra("#{skip}_unused")
              asm.label("#{skip}_unwalked")
              emit_places_prepared(asm, "#{skip}_unwalked_place") { emit_color_split_and_looked_up(asm, noted: false) }
              asm.bra("#{skip}_unused")
              asm.label("#{skip}_walked")
              asm.moveq(0, asm.d(0))
              emit_places_prepared(asm, "#{skip}_walked_place") { emit_split_color_looked_up(asm) }
              asm.label("#{skip}_unused")
              asm.subq(:w, 1, asm.d(4))
              asm.branch(:mi, skip)
              asm.label("#{skip}_cleared")
              asm.clr(:w, asm.post(3))
              asm.dbra(asm.d(4), "#{skip}_cleared")
              asm.label(skip)
            end

            # A loop over D7 + 1 places, each worked out by the block into D1 and stored at A3 (moved on).
            def emit_places_prepared(asm, label)
              asm.label(label)
              yield
              asm.move(:w, asm.d(1), asm.post(3))
              asm.dbra(asm.d(7), label)
            end

            # rt_colors_written, in the blank: each line of CRAM OWED marks written to its line of the colour
            # memory, the video chip pointed at the line's first place, eight longs written with no loop.
            def emit_written(asm, memory, at)
              h = Console::GenesisHardware
              asm.label("rt_colors_written")
              asm.move(:b, at.call(OWED), asm.d(0))
              asm.branch(:ne, "rt_colors_written_owed")
              asm.rts
              asm.label("rt_colors_written_owed")
              asm.clr(:b, at.call(OWED))
              asm.lea(asm.abs_l(h::VDP_DATA), asm.a(2))
              Art::PALETTES.times do |palette|
                skip = "rt_colors_written_line_#{palette}"
                line = palette * Art::PLACES * 2
                asm.btst(palette, asm.d(0))
                asm.branch(:eq, skip)
                asm.move(:l, asm.imm(h.command(h::WRITE_CRAM, line)), asm.abs_l(h::VDP_CONTROL))
                asm.lea(asm.abs_l(memory[CRAM], line), asm.a(1))
                (Art::PLACES / 2).times { asm.move(:l, asm.post(1), asm.ind(2)) }
                asm.label(skip)
              end
              asm.rts
            end
          end
        end
      end
    end
  end
end
