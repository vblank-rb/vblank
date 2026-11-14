# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PASS THAT PAINTS WHAT THE LAST ONE PAINTED, ON A SUPER FX CARTRIDGE: passed over whole,
          # so nothing is painted and nothing is sent.
          #
          # A plain cartridge keeps a log of every painting and paints again only the tiles that
          # come out different (PaintLog). There the 65816 paints each tile, and painting a tile
          # costs far more than comparing it. On a Super FX cartridge the chip paints the rectangles
          # and the pictures (ChipFill, ChipBlit) many times faster, so the cost that is left is
          # sending what was painted to video RAM, a blank at a time. A screen that clears and
          # paints the same things every pass (a menu, a score that stands still) sends the whole of
          # it every pass, and a plain cartridge sends none of it.
          #
          # So each pass's rectangles and pictures are WRITTEN DOWN as they are painted: their kind,
          # the area they were held to and their working numbers. The next pass's first clear of the
          # whole screen, to the colour it is cleared to already, is DEFERRED: the screen still holds
          # the last pass's picture. Each painting is then compared with the one written down at the
          # same place in the log; the same, it is passed over. A pass that ends having matched the
          # whole log is the screen as it is, and nothing changes.
          #
          # The first painting that differs, a pass that stops short of the log, or anything that
          # reads the screen or paints it some other way (a patch kept or put back, a routine on the
          # chip that draws columns) makes the clear at last (rt_repeat_apply): the next generation,
          # and each painting matched so far painted again from its entry. From there the pass
          # paints as it asks, and writes down what it paints.
          #
          # A pass is written down only from a clear of the whole screen, and only while the log has
          # room. Anything painted outside that (before the pass's first clear, past a full log, or
          # some other way) means the next pass cannot be the same as this one, and its clear is
          # made at once.
          #
          #   rt_repeat_apply_keeping  the clear deferred made, the direct page and the area kept
          #   rt_paint_at_once         the same, and the pass no longer the same as any other
          #   rt_paint_clear_made      the clear of the whole screen, made (Paint)
          module RepeatLog
            LOG = "rt repeat log"
            LOG_END = "rt repeat log end"
            LAST_PASS_END = "rt repeat last pass end"
            DEFERRED = "rt repeat deferred"
            RECORDING = "rt repeat recording"
            CLEARED = "rt repeat cleared"
            REPLAY_END = "rt repeat replay end"
            KEPT_PAGE = "rt repeat kept page"
            KEPT_AREA = "rt repeat kept area"
            NO_LAST_PASS = 0xFFFF
            # An entry: its kind, with Paint::AREA_PART in the high byte; the area's four words; the
            # working numbers, as many bytes as a fill takes.
            ENTRY_BYTES = 32
            ENTRY_AREA = 2
            ENTRY_NUMBERS = 10
            NUMBER_BYTES = 20
            KIND_FILL = 1
            KIND_BLIT = 2
            # Where each kind is painted, past its check.
            NOW = Ractor.make_shareable({ KIND_FILL => "rt_paint_fill_now", KIND_BLIT => "rt_paint_blit_now" })
            # The paintings a pass can write down, and the log's bytes. A pass of more paints them all
            # each pass, as a pass did before there was a log.
            ENTRIES = 256
            LOG_BYTES = ENTRIES * ENTRY_BYTES

            module_function

            def reserve(memory)
              memory.reserve_far(LOG, LOG_BYTES)
              [LOG_END, LAST_PASS_END, DEFERRED, RECORDING, CLEARED, REPLAY_END].each { |name| memory.reserve(name, 2) }
              memory.reserve(KEPT_AREA, Paint::AREA_WORDS * 2)
              memory.reserve_far(KEPT_PAGE, 0x100)
            end

            def kept?(memory) = memory.reserved?(LOG_END)

            # At power-on: nothing written down, and no last pass to be the same as.
            def emit_start(asm, memory)
              [LOG_END, DEFERRED, RECORDING, CLEARED].each { |name| asm.stz(asm.abs(memory[name])) }
              asm.lda(NO_LAST_PASS)
              asm.sta(asm.abs(memory[LAST_PASS_END]))
            end

            def emit(asm, memory)
              emit_apply(asm, memory)
              emit_at_once(asm, memory)
            end

            # At the top of a clear of the whole screen to the place in R0 (Paint's
            # rt_paint_clear_whole): DEFERRED, returning (RTL), when it is to the colour the screen
            # is cleared to already, the pass has made no clear yet and the last pass was written
            # down whole. While one is deferred, a second starts the comparing again from the top.
            # A clear to another colour is made, and with it any deferred.
            def emit_clear_deferred(asm, memory)
              asm.lda(asm.direct(Paint::R.call(0)))
              asm.cmp(asm.abs(memory[Paint::CLEAR_PLACE]))
              asm.bne("rt_repeat_clear_other_colour")
              asm.lda(asm.abs(memory[DEFERRED]))
              asm.bne("rt_repeat_clear_again")
              asm.lda(asm.abs(memory[CLEARED]))
              asm.bne("rt_repeat_clear_made")
              asm.lda(asm.abs(memory[LAST_PASS_END]))
              asm.cmp(NO_LAST_PASS)
              asm.beq("rt_repeat_clear_made")
              asm.lda(1)
              asm.sta(asm.abs(memory[DEFERRED]))
              asm.label("rt_repeat_clear_again")
              asm.stz(asm.abs(memory[LOG_END]))
              asm.rtl
              asm.label("rt_repeat_clear_other_colour")
              asm.stz(asm.abs(memory[DEFERRED]))
              asm.label("rt_repeat_clear_made")
            end

            # In rt_paint_clear_made, the clear made: written down from the top from here.
            def emit_cleared(asm, memory)
              asm.lda(1)
              asm.sta(asm.abs(memory[CLEARED]))
              asm.sta(asm.abs(memory[RECORDING]))
              asm.stz(asm.abs(memory[LOG_END]))
            end

            # At the start of a painting routine (JSL) of +kind+, known by +bytes+ of working numbers
            # (in the direct page from 0): while a clear is deferred, compared with the entry at
            # LOG_END and passed over (RTL) when it is the same; else written down, while the pass is.
            # Painting it again from the log starts at its NOW label, past this.
            def emit_check(asm, memory, kind, bytes)
              log = memory[LOG]
              area = memory[Paint::AREA]
              now = NOW.fetch(kind)
              differs = "#{now}_differs"
              asm.lda(asm.abs(memory[DEFERRED]))
              asm.branch_long(:beq, "#{now}_written")
              asm.ldx(asm.abs(memory[LOG_END]))
              asm.cpx(asm.abs(memory[LAST_PASS_END]))
              asm.branch_long(:bcs, differs)
              asm.lda(kind)
              asm.ora(asm.abs(area + Paint::AREA_PART))
              asm.cmp(asm.long_x(log))
              asm.branch_long(:bne, differs)
              (bytes / 2).times do |i|
                asm.lda(asm.direct(i * 2))
                asm.cmp(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
                asm.branch_long(:bne, differs)
              end
              asm.lda(asm.abs(area + Paint::AREA_PART))
              asm.beq("#{now}_same")
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.cmp(asm.long_x(log, ENTRY_AREA + (i * 2)))
                asm.branch_long(:bne, differs)
              end
              asm.label("#{now}_same")
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.sta(asm.abs(memory[LOG_END]))
              asm.rtl
              asm.label(differs)
              asm.jsr(asm.abs("rt_repeat_apply_keeping"))
              asm.label("#{now}_written")
              asm.lda(asm.abs(memory[RECORDING]))
              asm.beq("#{now}_at_once")
              asm.ldx(asm.abs(memory[LOG_END]))
              asm.cpx(LOG_BYTES)
              asm.bcc("#{now}_room")
              asm.stz(asm.abs(memory[RECORDING]))
              asm.label("#{now}_at_once")
              asm.lda(NO_LAST_PASS)
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.brl(now)
              asm.label("#{now}_room")
              asm.lda(kind)
              asm.ora(asm.abs(area + Paint::AREA_PART))
              asm.sta(asm.long_x(log))
              4.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.long_x(log, ENTRY_AREA + (i * 2)))
              end
              (bytes / 2).times do |i|
                asm.lda(asm.direct(i * 2))
                asm.sta(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
              end
              asm.txa
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.sta(asm.abs(memory[LOG_END]))
              asm.label(now)
            end

            # As a pass ends (Paint's rt_paint_prepare), before its rows are looked at: a pass that
            # matched the whole log changes nothing; one deferred that stopped short is made. Then
            # what the next pass is compared with: this pass's log, if it was written down whole.
            def emit_pass_end(asm, memory)
              asm.lda(asm.abs(memory[DEFERRED]))
              asm.beq("rt_repeat_pass_made")
              asm.lda(asm.abs(memory[LOG_END]))
              asm.cmp(asm.abs(memory[LAST_PASS_END]))
              asm.beq("rt_repeat_pass_same")
              asm.jsr(asm.abs("rt_repeat_apply_keeping"))
              asm.label("rt_repeat_pass_made")
              asm.lda(asm.abs(memory[RECORDING]))
              asm.beq("rt_repeat_pass_unwritten")
              asm.lda(asm.abs(memory[LOG_END]))
              asm.bra("rt_repeat_pass_known")
              asm.label("rt_repeat_pass_unwritten")
              asm.lda(NO_LAST_PASS)
              asm.label("rt_repeat_pass_known")
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.label("rt_repeat_pass_same")
              [DEFERRED, RECORDING, CLEARED].each { |name| asm.stz(asm.abs(memory[name])) }
            end

            # rt_repeat_apply_keeping (JSR): if a clear is deferred, it is made now (see the top): the
            # clear, and each painting matched so far painted again from its entry, with the direct
            # page and the area kept round it for the routine that asked. A, X and Y are not kept.
            def emit_apply(asm, memory)
              log = memory[LOG]
              area = memory[Paint::AREA]
              kept = memory[KEPT_PAGE]
              asm.label("rt_repeat_apply_keeping")
              asm.lda(asm.abs(memory[DEFERRED]))
              asm.bne("rt_repeat_apply_deferred")
              asm.rts
              asm.label("rt_repeat_apply_deferred")
              asm.stz(asm.abs(memory[DEFERRED]))
              Paint::AREA_WORDS.times do |i|
                asm.lda(asm.abs(area + (i * 2)))
                asm.sta(asm.abs(memory[KEPT_AREA] + (i * 2)))
              end
              asm.phb
              asm.lda(0xFF)
              asm.ldx(0)
              asm.ldy(kept & 0xFFFF)
              asm.mvn(kept >> 16, 0x00)
              asm.plb
              asm.lda(asm.abs(memory[LOG_END]))
              asm.sta(asm.abs(memory[REPLAY_END]))
              asm.jsr(asm.abs("rt_paint_clear_made"))
              asm.ldx(0)
              asm.label("rt_repeat_apply_entry")
              asm.cpx(asm.abs(memory[REPLAY_END]))
              asm.branch_long(:bcs, "rt_repeat_apply_done")
              asm.phx
              asm.lda(asm.long_x(log))
              asm.and_a(0xFF00)
              asm.sta(asm.abs(area + Paint::AREA_PART))
              4.times do |i|
                asm.lda(asm.long_x(log, ENTRY_AREA + (i * 2)))
                asm.sta(asm.abs(area + (i * 2)))
              end
              (NUMBER_BYTES / 2).times do |i|
                asm.lda(asm.long_x(log, ENTRY_NUMBERS + (i * 2)))
                asm.sta(asm.direct(i * 2))
              end
              asm.lda(asm.long_x(log))
              asm.and_a(0x00FF)
              asm.cmp(KIND_FILL)
              asm.bne("rt_repeat_apply_blit")
              asm.jsl(asm.long(NOW.fetch(KIND_FILL)))
              asm.bra("rt_repeat_apply_next")
              asm.label("rt_repeat_apply_blit")
              asm.jsl(asm.long(NOW.fetch(KIND_BLIT)))
              asm.label("rt_repeat_apply_next")
              asm.pla
              asm.clc
              asm.adc(ENTRY_BYTES)
              asm.tax
              asm.brl("rt_repeat_apply_entry")
              asm.label("rt_repeat_apply_done")
              asm.lda(asm.abs(memory[REPLAY_END]))
              asm.sta(asm.abs(memory[LOG_END]))
              asm.phb
              asm.lda(0xFF)
              asm.ldx(kept & 0xFFFF)
              asm.ldy(0)
              asm.mvn(0x00, kept >> 16)
              asm.plb
              Paint::AREA_WORDS.times do |i|
                asm.lda(asm.abs(memory[KEPT_AREA] + (i * 2)))
                asm.sta(asm.abs(area + (i * 2)))
              end
              asm.rts
            end

            # rt_paint_at_once (JSL), and rt_repeat_at_once (JSR): before something that reads the
            # screen or paints it without writing it down: the clear deferred made, and this pass
            # no longer one the next can be the same as.
            def emit_at_once(asm, memory)
              asm.label("rt_paint_at_once")
              asm.jsr(asm.abs("rt_repeat_at_once"))
              asm.rtl
              asm.label("rt_repeat_at_once")
              asm.jsr(asm.abs("rt_repeat_apply_keeping"))
              asm.stz(asm.abs(memory[RECORDING]))
              asm.lda(NO_LAST_PASS)
              asm.sta(asm.abs(memory[LAST_PASS_END]))
              asm.rts
            end
          end
        end
      end
    end
  end
end
