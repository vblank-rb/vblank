# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # Fades and tints. A Super Nintendo's colour maths can add or subtract a colour, or halve
          # the result, as it draws, but it cannot move a picture a fraction of the way toward
          # another colour; so a fade here is the colours in the colour memory (CGRAM) moved — all
          # 256, from the game's own ("art colors") into a copy in work RAM (SHADOW) that the blank
          # sends — by +steps+ 256ths of the way toward black, white or a colour, by the
          # interpreter's rule for a fade that walks the colours (Reference::Framebuffer#walked_toward
          # and #mixed), each of a colour's three five-bit channels apart:
          #
          #   toward black: c - c × steps / 256
          #   toward white: c + (31 - c) × steps / 256
          #   toward a colour t: (c × (256 - steps) + t × steps) / 256
          #
          # A channel is one of only 32 numbers, so the routine works out what each of them
          # becomes first — 32 for each channel, a table of 96 words, each already the channel's
          # place in the colour memory's word (rt_tint_table) — and then moves each colour by
          # looking its three channels up and putting the words together, with no shift of a
          # channel into place. Colour 0 is moved too: it is what shows where nothing is drawn, so
          # it fades with the picture.
          #
          # A fade to black is the display's own. The console has a master brightness, sixteen levels
          # in the low bits of INIDISP, which dims the finished picture as it goes out: nothing in
          # memory moves, so it costs a store in the blank however much is on the screen. A game's
          # own fades are done with it, so a game that fades to black (+dims+) notes how far down
          # the display is (DIMMED) and walks no colours for it, and the colours stay as they are,
          # free to be changed under the fade. Toward white or a colour there is no such thing, and
          # those still walk.
          #
          #   rt_tint(toward, color, steps)   the fade in force noted, or nothing when nothing changed
          #                                   (most frames of a game that sets its fade every frame)
          #   rt_tint_prepare                 as a pass ends (JSL): the colours moved, if the fade changed
          #   rt_tint_upload                  in the blank (JSR): the moved colours, if they changed
          module Tint
            TOWARD_BLACK = PaletteWalk::TOWARD_BLACK
            TOWARD_WHITE = PaletteWalk::TOWARD_WHITE
            TOWARD_COLOR = PaletteWalk::TOWARD_COLOR
            STEPS = FadeSteps::WALK
            CHANNEL_MAX = 31

            # The colours moved (512 bytes), and the fade in force: toward what, the colour, the
            # steps, whether the copy changed since the blank last sent it, the table of what each
            # channel's 32 numbers become, and two words of a bit for each of the sixteen palettes:
            # the palettes of the copy still to be sent (LINES_SENT), and the palettes a list changed
            # under the fade in force, whose colours are still to be moved (LINES_WALKED).
            SHADOW = "rt tint shadow"
            STATE = "rt tint"
            TOWARD = 0
            COLOR = 2
            STEPS_AT = 4
            CHANGED = 6
            TABLE = 8
            TABLE_BYTES = 3 * 32 * 2 # Three channels' 32 values, a word each (rt_tint_table)
            LINES_SENT = TABLE + TABLE_BYTES
            LINES_WALKED = LINES_SENT + 2
            STATE_BYTES = LINES_WALKED + 2
            ALL_LINES = 0xFFFF
            PALETTES = 16
            PALETTE_BYTES = 32 # A palette's sixteen colours, two bytes each

            # What CHANGED holds besides nought: a fade set this pass, whose colours are still to be
            # moved (rt_tint_prepare); colours moved and still to be sent (rt_tint_upload), the
            # palettes LINES_SENT marks; or a list changed under the fade in force, whose palettes
            # LINES_WALKED marks, still to be moved through the table as it is.
            TO_SEND = 1
            TO_WORK_OUT = 2
            TO_WALK = 3

            R = Ractor.make_shareable(->(n) { Memory.register(n) })

            # The direct page the routine works on. Moving the colours (rt_tint_apply_run) uses +product+ for
            # the end of the run it moves.
            Scratch = Data.define(:channel, :target, :factor, :product)

            module_function

            # The colours a game changes (`draw_with` on a background, `recolor`), for a game that
            # changes any: the 512 bytes a fade moves from, in work RAM, where without them it is
            # "art colors" in the cartridge. So a list held now and a fade in force meet: the list
            # goes in here and the fade moves what is here, on the same pass.
            COLORS_NOW = "rt colors now"

            # A palette's colours past the one every palette keeps for see-through.
            PALETTE_COLORS = 15

            # How many of the sixteen levels the display is down from full (FadeSteps.dimmed_levels).
            # Nought at power-on, which is full, so it needs no setting up.
            DIMMED = "rt tint dimmed"

            def reserve(memory, changing_colors: false, dims: false)
              memory.reserve_far(SHADOW, 512)
              memory.reserve(STATE, STATE_BYTES)
              memory.reserve_far(COLORS_NOW, 512) if changing_colors
              memory.reserve(DIMMED, 2) if dims
            end

            # In the blank: the display at the brightness the fade sets. Leaves A wide.
            def emit_brightness(asm, memory)
              h = Console::SNESHardware
              asm.lda(h::FULL_BRIGHTNESS)
              asm.sec
              asm.sbc(asm.abs(memory[DIMMED]))
              # Where the screen is off round a band the game named, the band's line table writes
              # the brightness (Letterbox).
              return asm.jsr(asm.abs("rt_letterbox_brightness")) if Letterbox.named_band?(memory)

              asm.sep(0x20)
              asm.sta(asm.abs(h::INIDISP))
              asm.rep(0x20)
            end

            def scratch(memory)
              Scratch.new(channel: memory.scratch(2), target: memory.scratch(2), factor: memory.scratch(2),
                          product: memory.scratch(2))
            end

            # +colors_shown+ is the runs of the colour memory a picture can show, as [first, count]
            # (Lowering::Picture#colors_shown): the colours the fade moves.
            # +changing_colors+ for a game that changes colours as it runs, which then fades from
            # COLORS_NOW and carries rt_colors_start and rt_colors_hold.
            # +scene_backdrops+ and +backdrop_follows+ carry rt_backdrop_hold, the second rt_backdrop_from too.
            def emit(asm, memory, s, colors_shown: [[0, 256]], changing_colors: false, dims: false, scene_backdrops: false,
                     backdrop_follows: false)
              emit_tint(asm, memory, s, dims, changing_colors)
              emit_table(asm, memory, s)
              emit_apply(asm, memory, s, colors_shown, changing_colors ? memory[COLORS_NOW] : "art colors")
              emit_lines_walked(asm, memory, s, colors_shown) if changing_colors
              emit_upload(asm, memory)
              emit_colors_held(asm, memory) if changing_colors
              emit_backdrop_held(asm, memory, follows: backdrop_follows) if scene_backdrops || backdrop_follows
            end

            # rt_backdrop_hold(color), for a game whose scenes differ in their backdrop or whose backdrop
            # follows a list of colours: colour 0 is +color+ in the place colours change in and in the
            # copy the blank sends, and the rest is rt_colors_hold's end, so a fade in force moves it on
            # the same pass.
            #
            # rt_backdrop_from(table, which), for the second: the backdrop's colour in the set +which+ of
            # the list, from a table of a count of the sets, the declared one among them, then the
            # backdrop's colour in each, the declared one first. A number naming none is the declared
            # set, as rt_colors_hold counts them.
            def emit_backdrop_held(asm, memory, follows: false)
              emit_backdrop_from(asm) if follows
              asm.label("rt_backdrop_hold")
              asm.lda(asm.direct(R.call(0)))
              asm.ldx(0)
              asm.sta(asm.long_x(memory[COLORS_NOW]))
              asm.sta(asm.long_x(memory[SHADOW]))
              asm.lda(1) # the backdrop is palette 0's
              asm.sta(asm.direct(R.call(1)))
              asm.jmp(asm.abs("rt_colors_hold_noted"))
            end

            # Falls through into rt_backdrop_hold, which #emit_backdrop_held writes next.
            def emit_backdrop_from(asm)
              asm.label("rt_backdrop_from")
              asm.lda(asm.direct(R.call(1) + 2))
              asm.bne("rt_backdrop_from_own")
              asm.lda(asm.direct(R.call(1)))
              asm.inc
              asm.cmp(asm.ind_long(R.call(0)))
              asm.bcc("rt_backdrop_from_set")
              asm.label("rt_backdrop_from_own")
              asm.lda(0)
              asm.label("rt_backdrop_from_set")
              asm.asl # a colour is two bytes
              asm.inc
              asm.inc # past the count
              asm.tay
              asm.lda(asm.ind_long_y(R.call(0)))
              asm.sta(asm.direct(R.call(0)))
            end

            # rt_colors_start (JSL, at power-on): the game's colours, into the place they change in and
            # into the copy the blank sends, which is then right for a list held with no fade.
            #
            # rt_colors_hold(table, which): the colours of the table's set +which+ in that place and in
            # that copy. With no fade in force the copy is then ready, and only those colours were
            # touched, so changing a list costs what its colours cost and not one move of every
            # colour on the screen. With a fade in force the colours are moved as the pass ends, as
            # a fade set this pass moves them, which writes over what went in the copy here, so
            # the two meet on the same pass whichever was given first. A fade that ended this pass
            # has its work still to do and keeps it. The table is a count, then each set's 24-bit
            # address in four bytes, the colours the game declared first: so a number naming none of
            # the others comes to that one, as Reference#colors_held_by says. A set is a count of
            # palettes, then for each its place in the 512 bytes and its PALETTE_COLORS colours.
            def emit_colors_held(asm, memory)
              state = memory[STATE]
              now = memory[COLORS_NOW]
              shadow = memory[SHADOW]
              set = R.call(2)
              palettes = R.call(3)
              colors = R.call(3) + 2
              lines = R.call(1) # the palettes written, once +which+ has been read: a bit each
              asm.label("rt_colors_start")
              asm.ldx(0)
              asm.label("rt_colors_start_color")
              asm.lda(asm.long_x("art colors"))
              asm.sta(asm.long_x(now))
              asm.sta(asm.long_x(shadow))
              asm.inx
              asm.inx
              asm.cpx(512)
              asm.bne("rt_colors_start_color")
              asm.rtl

              asm.label("rt_colors_hold")
              asm.lda(asm.direct(R.call(1) + 2))
              asm.bne("rt_colors_hold_own")
              asm.lda(asm.direct(R.call(1)))
              asm.inc
              asm.cmp(asm.ind_long(R.call(0)))
              asm.bcc("rt_colors_hold_set")
              asm.label("rt_colors_hold_own")
              asm.lda(0)
              asm.label("rt_colors_hold_set")
              asm.asl
              asm.asl
              asm.inc
              asm.inc
              asm.tay
              asm.lda(asm.ind_long_y(R.call(0)))
              asm.sta(asm.direct(set))
              asm.iny
              asm.iny
              asm.lda(asm.ind_long_y(R.call(0)))
              asm.sta(asm.direct(set + 2))
              asm.stz(asm.direct(lines))
              asm.lda(asm.ind_long(set))
              asm.sta(asm.direct(palettes))
              asm.ldy(2)
              asm.label("rt_colors_hold_palette")
              asm.lda(asm.ind_long_y(set))
              asm.tax
              5.times { asm.lsr } # the palette's place, a palette of 32 bytes
              asm.asl
              asm.phx
              asm.tax
              asm.lda(asm.long_x("rt_tint_line_bits"))
              asm.ora(asm.direct(lines))
              asm.sta(asm.direct(lines))
              asm.plx
              asm.iny
              asm.iny
              asm.lda(PALETTE_COLORS)
              asm.sta(asm.direct(colors))
              asm.label("rt_colors_hold_color")
              asm.lda(asm.ind_long_y(set))
              asm.sta(asm.long_x(now))
              asm.sta(asm.long_x(shadow))
              asm.inx
              asm.inx
              asm.iny
              asm.iny
              asm.dec(asm.direct(colors))
              asm.bne("rt_colors_hold_color")
              asm.dec(asm.direct(palettes))
              asm.bne("rt_colors_hold_palette")
              # The palettes written, in +lines+: with no fade in force they are ready in the copy and
              # owed to the blank; with one they are owed to rt_tint_prepare, which moves them alone
              # through the table as it is. A fade set this pass has every colour to move and keeps it.
              asm.label("rt_colors_hold_noted")
              asm.lda(asm.abs(state + STEPS_AT))
              asm.bne("rt_colors_hold_faded")
              asm.lda(asm.direct(lines))
              asm.ora(asm.abs(state + LINES_SENT))
              asm.sta(asm.abs(state + LINES_SENT))
              asm.lda(asm.abs(state + CHANGED))
              asm.bne("rt_colors_hold_done")
              asm.lda(TO_SEND)
              asm.bra("rt_colors_hold_note")
              asm.label("rt_colors_hold_faded")
              asm.lda(asm.direct(lines))
              asm.ora(asm.abs(state + LINES_WALKED))
              asm.sta(asm.abs(state + LINES_WALKED))
              asm.lda(asm.abs(state + CHANGED))
              asm.cmp(TO_WORK_OUT)
              asm.beq("rt_colors_hold_done")
              asm.lda(TO_WALK)
              asm.label("rt_colors_hold_note")
              asm.sta(asm.abs(state + CHANGED))
              asm.label("rt_colors_hold_done")
              asm.rtl

              asm.label("rt_tint_line_bits")
              asm.data_words(*Array.new(PALETTES) { |palette| 1 << palette })
            end

            # The steps held to 0..256 (PaletteWalk's range, held here once rather than at every call:
            # see PaletteWalk) and, when the fade is not the one in force, the colours moved.
            def emit_tint(asm, memory, s, dims, changing_colors)
              state = memory[STATE]
              asm.label("rt_tint")
              asm.lda(asm.direct(R.call(2) + 2))
              asm.bmi("rt_tint_none")
              asm.bne("rt_tint_all")
              asm.lda(asm.direct(R.call(2)))
              asm.cmp(STEPS + 1)
              asm.bcc("rt_tint_held")
              asm.label("rt_tint_all")
              asm.lda(STEPS)
              asm.bra("rt_tint_held")
              asm.label("rt_tint_none")
              asm.lda(0)
              asm.label("rt_tint_held")
              asm.sta(asm.direct(R.call(2)))
              emit_dimming(asm, memory) if dims
              # The same as before: nothing to do. No steps at all is the colours as they are,
              # whatever they were moved toward.
              asm.cmp(asm.abs(state + STEPS_AT))
              asm.bne("rt_tint_changed")
              asm.cmp(0)
              asm.beq("rt_tint_same")
              asm.lda(asm.direct(R.call(0)))
              asm.cmp(asm.abs(state + TOWARD))
              asm.bne("rt_tint_changed")
              asm.lda(asm.direct(R.call(1)))
              asm.cmp(asm.abs(state + COLOR))
              asm.bne("rt_tint_changed")
              asm.label("rt_tint_same")
              asm.rtl
              asm.label("rt_tint_changed")
              [[R.call(0), TOWARD], [R.call(1), COLOR], [R.call(2), STEPS_AT]].each do |from, to|
                asm.lda(asm.direct(from))
                asm.sta(asm.abs(state + to))
              end
              asm.lda(TO_WORK_OUT)
              asm.sta(asm.abs(state + CHANGED))
              asm.rtl

              # rt_tint_prepare (JSL, as a pass ends): the colours moved by the fade in force, if it
              # changed this pass. Only the fade in force as the pass ends is ever sent, so a pass
              # that sets several — a fade that catches up on the frames a slow pass took sets one
              # for each — moves the colours once, not once for each.
              asm.label("rt_tint_prepare")
              asm.lda(asm.abs(state + CHANGED))
              asm.cmp(TO_WORK_OUT)
              asm.bne("rt_tint_prepare_lines")
              asm.jsr(asm.abs("rt_tint_table"))
              asm.jsr(asm.abs("rt_tint_apply"))
              asm.lda(ALL_LINES)
              asm.sta(asm.abs(state + LINES_SENT))
              asm.stz(asm.abs(state + LINES_WALKED))
              asm.bra("rt_tint_prepare_sent")
              # A list changed under the fade in force: its palettes alone, through the table as it is.
              asm.label("rt_tint_prepare_lines")
              if changing_colors
                asm.cmp(TO_WALK)
                asm.bne("rt_tint_prepare_done")
                asm.jsr(asm.abs("rt_tint_apply_lines"))
                asm.lda(asm.abs(state + LINES_WALKED))
                asm.ora(asm.abs(state + LINES_SENT))
                asm.sta(asm.abs(state + LINES_SENT))
                asm.stz(asm.abs(state + LINES_WALKED))
              else
                asm.bra("rt_tint_prepare_done")
              end
              asm.label("rt_tint_prepare_sent")
              asm.lda(TO_SEND)
              asm.sta(asm.abs(state + CHANGED))
              asm.label("rt_tint_prepare_done")
              asm.rtl

              # rt_tint_times (JSR): A = the byte at +channel+ times the number at +factor+, by the
              # console's multiplier. The multiplier takes a byte, and a factor of 256 — a fade all
              # the way, or none of it kept — is one more: that product is the channel moved up a
              # byte, which swapping A's two bytes does.
              asm.label("rt_tint_times")
              asm.lda(asm.direct(s.factor))
              asm.cmp(STEPS)
              asm.bne("rt_tint_times_byte")
              asm.lda(asm.direct(s.channel))
              asm.xba
              asm.rts
              asm.label("rt_tint_times_byte")
              asm.sep(0x20)
              asm.lda(asm.direct(s.channel))
              asm.sta(asm.abs(Console::SNESHardware::WRMPYA))
              asm.lda(asm.direct(s.factor))
              asm.sta(asm.abs(Console::SNESHardware::WRMPYB))
              4.times { asm.nop } # the eight cycles the multiplier takes
              asm.rep(0x20)
              asm.lda(asm.abs(Console::SNESHardware::RDMPYL))
              asm.rts
            end

            # In rt_tint, A the steps: toward black they become how far down the display is
            # (FadeSteps.dimmed_levels), and no steps are left for the colours to walk. Anything
            # else leaves the display at full. Leaves A the steps left.
            def emit_dimming(asm, memory)
              asm.lda(asm.direct(R.call(0)))
              asm.cmp(TOWARD_BLACK)
              asm.beq("rt_tint_dims")
              asm.stz(asm.abs(memory[DIMMED]))
              asm.lda(asm.direct(R.call(2)))
              asm.bra("rt_tint_dimmed")
              asm.label("rt_tint_dims")
              asm.lda(15) # all the way down is for all the way alone
              asm.ldx(asm.direct(R.call(2)))
              asm.cpx(STEPS)
              asm.bcs("rt_tint_dims_kept")
              asm.lda(asm.direct(R.call(2)))
              4.times { asm.asl }
              asm.sec
              asm.sbc(asm.direct(R.call(2)))
              emit_over_256(asm)
              asm.label("rt_tint_dims_kept")
              asm.sta(asm.abs(memory[DIMMED]))
              asm.stz(asm.direct(R.call(2)))
              asm.lda(0)
              asm.label("rt_tint_dimmed")
            end

            # A divided by 256: its high byte, swapped down and the low one dropped.
            def emit_over_256(asm)
              asm.xba
              asm.and_a(0xFF)
            end

            # rt_tint_table (JSR): what each channel's 32 numbers become by the fade in force, each as
            # the word of the colour memory that channel is (BGR555, red in the low five bits: fullsnes,
            # "CGRAM"), so moving a colour is three words read and put together.
            #
            # All three walks are one sum, (c × keep + add) ÷ 256, with keep = 256 - steps and an add
            # for each channel that does not hang on c: 255 toward black (c less a share rounded down
            # is the share kept rounded up), 31 × steps toward white, and the colour's channel × steps
            # toward a colour. The sum is under 2^13 and its high byte is the channel, so a table is
            # the sum walked from one value to the next by adding keep, with no multiply: the
            # multiplier is asked only for the colour's three adds. Toward black or white the adds
            # are the same, so one sum makes all three tables. A channel's word is the sum's high byte
            # (XBA) for red, the sum shifted right three for green and left two for blue, each masked.
            #
            # The tables (TABLE): red's 32 words, then green's and blue's side by side, four bytes a
            # value, so a colour's green and blue are each found by one mask of the colour (see
            # rt_tint_apply_run).
            RED_TABLE = 0
            GREEN_BLUE_TABLE = 32 * 2
            CHANNEL_WORD_MASKS = [0x001F, 0x03E0, 0x7C00].freeze

            def emit_table(asm, memory, s)
              state = memory[STATE]
              steps = asm.abs(state + STEPS_AT)
              asm.label("rt_tint_table")
              asm.lda(asm.abs(state + TOWARD))
              asm.cmp(TOWARD_WHITE)
              asm.beq("rt_tint_table_white")
              asm.bcs("rt_tint_table_color")
              asm.lda(255)
              asm.bra("rt_tint_table_one_sum")
              asm.label("rt_tint_table_white")
              asm.lda(steps)
              5.times { asm.asl }
              asm.sec
              asm.sbc(steps) # 31 × steps
              asm.label("rt_tint_table_one_sum")
              asm.sta(asm.direct(s.channel))
              emit_keep(asm, s, steps)
              asm.label("rt_tint_table_one_sum_value")
              emit_table_words(asm, state, s, one_sum: true)
              asm.lda(asm.direct(s.channel))
              asm.clc
              asm.adc(asm.direct(s.factor))
              asm.sta(asm.direct(s.channel))
              emit_table_value_done(asm, "rt_tint_table_one_sum_value")
              # Toward a colour: each channel's add from the multiplier, kept on the stack while the
              # multiplier's own words are in use.
              asm.label("rt_tint_table_color")
              3.times do |channel|
                asm.lda(asm.abs(state + COLOR))
                (channel * 5).times { asm.lsr }
                asm.and_a(CHANNEL_MAX)
                asm.sta(asm.direct(s.channel))
                asm.lda(steps)
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                asm.pha
              end
              [s.product, s.target, s.channel].each do |sum|
                asm.pla
                asm.sta(asm.direct(sum))
              end
              # The three sums are red's in +channel+, green's in +target+ and blue's in +product+;
              # keep in +factor+.
              emit_keep(asm, s, steps)
              asm.label("rt_tint_table_value")
              emit_table_words(asm, state, s, one_sum: false)
              [s.channel, s.target, s.product].each do |sum|
                asm.lda(asm.direct(sum))
                asm.clc
                asm.adc(asm.direct(s.factor))
                asm.sta(asm.direct(sum))
              end
              emit_table_value_done(asm, "rt_tint_table_value")
            end

            # Keep, 256 less the steps, into +factor+, and X and Y at the tables' first values.
            def emit_keep(asm, s, steps)
              asm.lda(STEPS)
              asm.sec
              asm.sbc(steps)
              asm.sta(asm.direct(s.factor))
              asm.ldx(0)
              asm.ldy(0)
            end

            # The three words of one value: red's at X, green's and blue's at Y, from red's sum in
            # +channel+, green's in +target+ and blue's in +product+, or all three from +channel+ with
            # +one_sum+.
            def emit_table_words(asm, state, s, one_sum:)
              green, blue = one_sum ? [s.channel, s.channel] : [s.target, s.product]
              asm.lda(asm.direct(s.channel))
              asm.xba
              asm.and_a(CHANNEL_WORD_MASKS[0])
              asm.sta(asm.abs_x(state + TABLE + RED_TABLE))
              asm.lda(asm.direct(green))
              3.times { asm.lsr }
              asm.and_a(CHANNEL_WORD_MASKS[1])
              asm.sta(asm.abs_y(state + TABLE + GREEN_BLUE_TABLE))
              asm.lda(asm.direct(blue))
              2.times { asm.asl }
              asm.and_a(CHANNEL_WORD_MASKS[2])
              asm.sta(asm.abs_y(state + TABLE + GREEN_BLUE_TABLE + 2))
            end

            # The next value, or the end of the tables.
            def emit_table_value_done(asm, again)
              4.times { asm.iny }
              asm.inx
              asm.inx
              asm.cpx(32 * 2)
              asm.bne(again)
              asm.rts
            end

            # rt_tint_apply (JSR): each colour of the game's a picture can show moved into the copy,
            # through the table. Moving a colour is the most of a fade's work, so only the runs of
            # +colors_shown+ are moved: a game whose pictures use one palette moves its sixteen
            # colours, the backdrop among them, not 256. The others are never drawn from, and stay as nought in the copy.
            # +from+ is where the colours are moved from.
            def emit_apply(asm, memory, s, colors_shown, from)
              state = memory[STATE]
              shadow = memory[SHADOW]
              asm.label("rt_tint_apply")
              colors_shown.each { |first, count| emit_run_applied(asm, s, first, count) }
              asm.rts

              # rt_tint_apply_run (JSR): the colours from X up to the byte at +product+ moved, each
              # channel's word read from its table at an index the colour gives with one mask:
              # red's, two bytes a value, is the colour shifted left once; green's and blue's, four
              # bytes a value, are the colour shifted right three, and its two bytes swapped (XBA),
              # which brings blue down to the bits green's index takes. +channel+ holds the word as it
              # is put together.
              asm.label("rt_tint_apply_run")
              asm.lda(asm.long_x(from))
              asm.asl
              asm.and_a(0x003E)
              asm.tay
              asm.lda(asm.abs_y(state + TABLE + RED_TABLE))
              asm.sta(asm.direct(s.channel))
              asm.lda(asm.long_x(from))
              3.times { asm.lsr }
              asm.and_a(0x007C)
              asm.tay
              asm.lda(asm.abs_y(state + TABLE + GREEN_BLUE_TABLE))
              asm.ora(asm.direct(s.channel))
              asm.sta(asm.direct(s.channel))
              asm.lda(asm.long_x(from))
              asm.xba
              asm.and_a(0x007C)
              asm.tay
              asm.lda(asm.abs_y(state + TABLE + GREEN_BLUE_TABLE + 2))
              asm.ora(asm.direct(s.channel))
              asm.sta(asm.long_x(shadow))
              asm.inx
              asm.inx
              asm.cpx(asm.direct(s.product))
              asm.bne("rt_tint_apply_run")
              asm.rts
            end

            # A call of rt_tint_apply_run for the +count+ colours from +first+.
            def emit_run_applied(asm, s, first, count)
              return if count.zero?

              asm.ldx(first * 2)
              asm.lda((first + count) * 2)
              asm.sta(asm.direct(s.product))
              asm.jsr(asm.abs("rt_tint_apply_run"))
            end

            # rt_tint_apply_lines (JSR): the colours of each palette LINES_WALKED marks moved, those of it a
            # picture can show (+colors_shown+), through the table as it is. A list changed under a fade in
            # force moves its own palettes and no other colour, and the table is not worked out again.
            def emit_lines_walked(asm, memory, s, colors_shown)
              walked = memory[STATE] + LINES_WALKED
              asm.label("rt_tint_apply_lines")
              PALETTES.times do |palette|
                runs = colors_shown.filter_map do |first, count|
                  from = [first, palette * 16].max
                  to = [first + count, (palette + 1) * 16].min
                  [from, to - from] if to > from
                end
                next if runs.empty?

                skip = "rt_tint_apply_lines_#{palette}"
                asm.lda(asm.abs(walked))
                asm.and_a(1 << palette)
                asm.beq(skip)
                runs.each { |first, count| emit_run_applied(asm, s, first, count) }
                asm.label(skip)
              end
              asm.rts
            end

            # rt_tint_upload (JSR, in the blank): the moved colours, if they changed since the last
            # blank. Each screen sends them in one blank with the rest of what shows the pass, and
            # counts them against that blank's room (Picture's rt_upload_copy, Paint's
            # rt_paint_upload), so a moved colour never shows on the last pass's picture. A fade
            # sends the whole colour memory in one copy; a list told other colours sends its own
            # palettes alone, each a copy of 32 bytes to the palette's place in the colour memory
            # (CGADD, then CGDATA a byte at a time: fullsnes, "CGRAM"), so changing one list costs
            # what its sixteen colours cost to send and not the 512 bytes of the screen's.
            def emit_upload(asm, memory)
              h = Console::SNESHardware
              state = memory[STATE]
              shadow = memory[SHADOW]
              sent = state + LINES_SENT
              asm.label("rt_tint_upload")
              asm.lda(asm.abs(state + CHANGED))
              asm.cmp(TO_SEND)
              asm.bne("rt_tint_upload_none")
              asm.stz(asm.abs(state + CHANGED))
              asm.lda(asm.abs(sent))
              asm.cmp(ALL_LINES)
              asm.bne("rt_tint_upload_lines")
              asm.stz(asm.abs(sent))
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm(shadow & 0xFFFF), shadow >> 16, 512)
              asm.label("rt_tint_upload_none")
              asm.rts

              # A palette at a time, X its first byte in the copy: LINES_SENT is shifted down as it is
              # read, so it is nought when the last palette marked is sent.
              # The sprites' eight palettes are the top eight, so a list of sprite colours starts the walk
              # there rather than testing eight palettes it did not change.
              asm.label("rt_tint_upload_lines")
              asm.ldx(0)
              asm.and_a(0x00FF)
              asm.bne("rt_tint_upload_line")
              asm.lda(asm.abs(sent))
              asm.xba
              asm.and_a(0x00FF)
              asm.sta(asm.abs(sent))
              asm.ldx(8 * PALETTE_BYTES)
              asm.label("rt_tint_upload_line")
              asm.lsr(asm.abs(sent))
              asm.bcc("rt_tint_upload_line_next")
              asm.txa
              asm.lsr # the palette's first colour, a word of the colour memory each
              asm.sep(0x20)
              asm.sta(asm.abs(h::CGADD))
              asm.rep(0x20)
              asm.txa
              asm.clc
              asm.adc(shadow & 0xFFFF)
              asm.sta(asm.abs(h::DMA_BASE + h::A1TL))
              asm.lda(PALETTE_BYTES)
              asm.sta(asm.abs(h::DMA_BASE + h::DASL))
              asm.sep(0x20)
              asm.lda(shadow >> 16)
              asm.sta(asm.abs(h::DMA_BASE + h::A1B))
              asm.lda(h::DMA_TO_ONE_PORT)
              asm.sta(asm.abs(h::DMA_BASE + h::DMAP))
              asm.lda(h::CGDATA & 0xFF)
              asm.sta(asm.abs(h::DMA_BASE + h::BBAD))
              asm.lda(1)
              asm.sta(asm.abs(h::MDMAEN))
              asm.rep(0x20)
              asm.label("rt_tint_upload_line_next")
              asm.txa
              asm.clc
              asm.adc(PALETTE_BYTES)
              asm.tax
              asm.lda(asm.abs(sent))
              asm.bne("rt_tint_upload_line")
              asm.rts
            end
          end
        end
      end
    end
  end
end
