# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # FADES AND TINTS. A Super Nintendo's colour maths can add or subtract a colour, or halve
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
          # becomes first — 32 for each channel, a table of 96 — with the console's own 8×8
          # multiplier (WRMPYA and WRMPYB, the product at RDMPYL eight cycles later), and then
          # moves each colour by looking its three channels up. Colour 0 is moved too: it is what
          # shows where nothing is drawn, so it fades with the picture.
          #
          # A FADE TO BLACK IS THE DISPLAY'S OWN. The console has a master brightness, sixteen levels
          # in the low bits of INIDISP, which dims the finished picture as it goes out: nothing in
          # memory moves, so it costs a store in the blank however much is on the screen. A game's
          # own fades are done with it, so a game that fades to black (+dims+) notes how far down
          # the display is (DIMMED) and walks no colours for it, and the colours stay as they are,
          # free to be changed under the fade. Toward white or a colour there is no such thing, and
          # those still walk.
          #
          #   rt_tint(toward, color, steps)   the fade in force noted, or nothing when nothing changed
          #                                   (most frames of a game that says its fade every frame)
          #   rt_tint_prepare                 as a pass ends (JSL): the colours moved, if the fade changed
          #   rt_tint_upload                  in the blank (JSR): the moved colours, if they changed
          module Tint
            TOWARD_BLACK = 0
            TOWARD_WHITE = 1
            TOWARD_COLOR = 2
            STEPS = FadeSteps::WALK
            CHANNEL_MAX = 31

            # The colours moved (512 bytes), and the fade in force: toward what, the colour, the
            # steps, whether the copy changed since the blank last sent it, and the table of what
            # each channel's 32 numbers become.
            SHADOW = "rt tint shadow"
            STATE = "rt tint"
            TOWARD = 0
            COLOR = 2
            STEPS_AT = 4
            CHANGED = 6
            TABLE = 8
            STATE_BYTES = TABLE + (3 * 32)

            # What CHANGED holds besides nought: a fade said this pass, whose colours are still to be
            # moved (rt_tint_prepare), or colours moved and still to be sent (rt_tint_upload).
            TO_SEND = 1
            TO_WORK_OUT = 2

            R = Ractor.make_shareable(->(n) { Memory.register(n) })

            # The direct page the routine works on.
            Scratch = Data.define(:channel, :target, :factor, :product)

            module_function

            # THE COLOURS A GAME CHANGES (`draw_with` on a background, `recolor`), for a game that
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

            # In the blank: the display at the brightness the fade says. Leaves A wide.
            def emit_brightness(asm, memory)
              h = Console::SNESHardware
              asm.lda(h::FULL_BRIGHTNESS)
              asm.sec
              asm.sbc(asm.abs(memory[DIMMED]))
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
            def emit(asm, memory, s, colors_shown: [[0, 256]], changing_colors: false, dims: false)
              emit_tint(asm, memory, s, dims)
              emit_table(asm, memory, s)
              emit_apply(asm, memory, colors_shown, changing_colors ? memory[COLORS_NOW] : "art colors")
              emit_upload(asm, memory)
              emit_colors_held(asm, memory) if changing_colors
            end

            # rt_colors_start (JSL, at power-on): the game's colours, into the place they change in and
            # into the copy the blank sends, which is then right for a list held with no fade.
            #
            # rt_colors_hold(table, which): the colours of the table's set +which+ in that place and in
            # that copy. With no fade in force the copy is then ready, and only those colours were
            # touched, so changing a list costs what its colours cost and not one move of every
            # colour on the screen. With a fade in force the colours are moved as the pass ends, as
            # a fade said this pass moves them, which writes over what went in the copy here, so
            # the two meet on the same pass whichever was said first. A fade that ended this pass
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
              asm.lda(asm.ind_long(set))
              asm.sta(asm.direct(palettes))
              asm.ldy(2)
              asm.label("rt_colors_hold_palette")
              asm.lda(asm.ind_long_y(set))
              asm.tax
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
              asm.lda(asm.abs(state + STEPS_AT))
              asm.bne("rt_colors_hold_faded")
              asm.lda(asm.abs(state + CHANGED))
              asm.bne("rt_colors_hold_done")
              asm.lda(TO_SEND)
              asm.bra("rt_colors_hold_note")
              asm.label("rt_colors_hold_faded")
              asm.lda(TO_WORK_OUT)
              asm.label("rt_colors_hold_note")
              asm.sta(asm.abs(state + CHANGED))
              asm.label("rt_colors_hold_done")
              asm.rtl
            end

            # The steps held to 0..256 and, when the fade is not the one in force, the colours moved.
            def emit_tint(asm, memory, s, dims)
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
              # that says several — a fade that catches up on the frames a slow pass took says one
              # for each — moves the colours once, not once for each.
              asm.label("rt_tint_prepare")
              asm.lda(asm.abs(state + CHANGED))
              asm.cmp(TO_WORK_OUT)
              asm.bne("rt_tint_prepare_done")
              asm.jsr(asm.abs("rt_tint_table"))
              asm.jsr(asm.abs("rt_tint_apply"))
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

            # rt_tint_table (JSR): what each channel's 32 numbers become, for red, green and blue in
            # turn (the colour moved toward has a channel of each), by the fade in force.
            def emit_table(asm, memory, s)
              state = memory[STATE]
              asm.label("rt_tint_table")
              asm.ldx(0)
              3.times do |channel|
                asm.lda(asm.abs(state + COLOR))
                (channel * 5).times { asm.lsr }
                asm.and_a(CHANNEL_MAX)
                asm.sta(asm.direct(s.target))
                asm.stz(asm.direct(s.channel))
                asm.label("rt_tint_table_#{channel}")
                asm.lda(asm.abs(state + TOWARD))
                asm.cmp(TOWARD_WHITE)
                asm.beq("rt_tint_table_#{channel}_white")
                asm.bcs("rt_tint_table_#{channel}_color")
                # Toward black: the channel less its share.
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                emit_over_256(asm)
                asm.sta(asm.direct(s.product))
                asm.lda(asm.direct(s.channel))
                asm.sec
                asm.sbc(asm.direct(s.product))
                asm.bra("rt_tint_table_#{channel}_kept")
                # Toward white: the channel and its share of the room above it.
                asm.label("rt_tint_table_#{channel}_white")
                asm.lda(asm.direct(s.channel))
                asm.pha
                asm.eor(CHANNEL_MAX) # 31 less it, for a number of five bits
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                emit_over_256(asm)
                asm.sta(asm.direct(s.product))
                asm.pla
                asm.sta(asm.direct(s.channel))
                asm.clc
                asm.adc(asm.direct(s.product))
                asm.bra("rt_tint_table_#{channel}_kept")
                # Toward a colour: the channel's share and the colour's, added, then divided.
                asm.label("rt_tint_table_#{channel}_color")
                asm.lda(STEPS)
                asm.sec
                asm.sbc(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                asm.sta(asm.direct(s.product))
                asm.lda(asm.direct(s.channel))
                asm.pha
                asm.lda(asm.direct(s.target))
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.abs(state + STEPS_AT))
                asm.sta(asm.direct(s.factor))
                asm.jsr(asm.abs("rt_tint_times"))
                asm.clc
                asm.adc(asm.direct(s.product))
                emit_over_256(asm)
                asm.sta(asm.direct(s.product))
                asm.pla
                asm.sta(asm.direct(s.channel))
                asm.lda(asm.direct(s.product))
                asm.label("rt_tint_table_#{channel}_kept")
                asm.sep(0x20)
                asm.sta(asm.abs_x(state + TABLE))
                asm.rep(0x20)
                asm.inx
                asm.inc(asm.direct(s.channel))
                asm.lda(asm.direct(s.channel))
                asm.cmp(32)
                asm.branch_long(:bcc, "rt_tint_table_#{channel}")
              end
              asm.rts
            end

            # rt_tint_apply (JSR): each colour of the game's a picture can show moved into the copy,
            # through the table. Moving a colour is the most of a fade's work, so only the runs of
            # +colors_shown+ are moved: a game whose pictures use one palette moves its sixteen
            # colours, the backdrop among them, not 256. The others are never drawn from, and stay as nought in the copy.
            # +from+ is where the colours are moved from.
            def emit_apply(asm, memory, colors_shown, from)
              state = memory[STATE]
              shadow = memory[SHADOW]
              asm.label("rt_tint_apply")
              colors_shown.each_with_index do |(first, count), run|
                next if count.zero?

                asm.ldx(first * 2)
                asm.label("rt_tint_apply_color_#{run}")
                asm.lda(0)
                asm.sta(asm.long_x(shadow))
                3.times do |channel|
                  asm.lda(asm.long_x(from))
                  (channel * 5).times { asm.lsr }
                  asm.and_a(CHANNEL_MAX)
                  asm.phx
                  asm.tax
                  asm.lda(asm.abs_x(state + TABLE + (channel * 32)))
                  asm.plx
                  asm.and_a(CHANNEL_MAX)
                  (channel * 5).times { asm.asl }
                  asm.ora(asm.long_x(shadow))
                  asm.sta(asm.long_x(shadow))
                end
                asm.inx
                asm.inx
                asm.cpx((first + count) * 2)
                asm.bne("rt_tint_apply_color_#{run}")
              end
              asm.rts
            end

            # rt_tint_upload (JSR, in the blank): the moved colours, if they changed since the last
            # blank. Each screen sends them in one blank with the rest of what shows the pass, and
            # counts them against that blank's room (Picture's rt_upload_copy, Paint's
            # rt_paint_upload), so a moved colour never shows on the last pass's picture.
            def emit_upload(asm, memory)
              h = Console::SNESHardware
              state = memory[STATE]
              shadow = memory[SHADOW]
              asm.label("rt_tint_upload")
              asm.lda(asm.abs(state + CHANGED))
              asm.cmp(TO_SEND)
              asm.bne("rt_tint_upload_none")
              asm.stz(asm.abs(state + CHANGED))
              asm.sep(0x20)
              asm.stz(asm.abs(h::CGADD))
              asm.rep(0x20)
              Picture.emit_dma(asm, h::DMA_TO_ONE_PORT, h::CGDATA, asm.imm(shadow & 0xFFFF), shadow >> 16, 512)
              asm.label("rt_tint_upload_none")
              asm.rts
            end
          end
        end
      end
    end
  end
end
