# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A BACKGROUND SHOWN ONLY INSIDE A BOX THE GAME MOVES AND SIZES (`show_only_inside`), held
          # there by the display's windows (fullsnes, "SNES PPU Window").
          #
          # A window is a span of each line, from a left edge to a right edge, both inclusive
          # (WH0/WH1 for window 1, WH2/WH3 for window 2). For each layer, W12SEL turns a window on
          # and says whether it covers the inside of the span or the outside; TMW then hides the
          # layer, on the main screen, wherever its window covers. So BG1 takes window 1 and BG2
          # window 2, each set to cover the OUTSIDE of its span: the layer shows only inside it. A
          # span whose left edge is past its right is empty, so its outside is the whole line, and
          # the layer shows nowhere on that line.
          #
          # The edges are one pair for the whole line, so the box's top and bottom are lines where
          # the edges change: the copying engine writes them a line at a time (HDMA) from a short
          # table for each layer, made in the blank whenever the game moved a box: an empty span for
          # the lines above the box, the box's span for its lines, and an empty span to the bottom.
          # A step counts 127 lines at most, so a run longer than that takes two. Channel 4 writes
          # BG1's edges and channel 5 BG2's, two registers a line (DMAP's two-ports way, WH0 and WH1
          # or WH2 and WH3); the bar's line table is channel 1 and the bends' 2 and 3. Channels 4 to
          # 7 are a painted screen's (Paint, Letterbox), and a painted screen has no backgrounds.
          #
          #   rt_background_box(layer, held, left, top, right, bottom)
          #       +layer+ held to the box (+held+ not nought), its edges already on the screen with
          #       right and bottom just past it (Lowering::Picture#emit_box_background), or shown
          #       everywhere (+held+ nought); from the next blank on
          #   rt_background_box_upload   in the blank (JSR): each layer's table made again, and the
          #                              windows set, where a box changed
          module BackgroundBox
            # For each of the two layers: whether it is held to a box, then the box's left, top,
            # right and bottom (a word each). Then whether any changed since the last blank.
            STATE = "rt background boxes"
            HELD = 0
            LEFT = 2
            TOP = 4
            RIGHT = 6
            BOTTOM = 8
            LAYER_BYTES = 10
            LAYERS = 2
            CHANGED = LAYERS * LAYER_BYTES
            STATE_BYTES = CHANGED + 2
            # Each layer's line table: two steps above the box, two for it, one below and the end,
            # three bytes a step.
            def self.table(layer) = "rt background box table #{layer}"
            TABLE_BYTES = (5 * 3) + 1
            CHANNELS = [4, 5].freeze
            # Where each layer's window's edges are written: WH0 for window 1, WH2 for window 2.
            EDGES = [Console::SNESHardware::WH0, Console::SNESHardware::WH2].freeze
            # W12SEL: BG1's window 1 on (bit 1) covering outside its span (bit 0), and BG2's window 2
            # on (bit 7) covering outside its span (bit 6).
            WINDOWS_OUTSIDE = 0xC3
            # An empty span: its left edge past its right.
            EMPTY_LEFT = 0xFF
            EMPTY_RIGHT = 0x00
            MOST_STEP_LINES = Picture::MOST_STEP_LINES

            module_function

            def reserve(memory)
              memory.reserve(STATE, STATE_BYTES)
              LAYERS.times { |layer| memory.reserve(table(layer), TABLE_BYTES) }
            end

            def kept?(memory) = memory.reserved?(STATE)

            # +work+ is four words of the direct page the blank's routines use.
            def emit(asm, memory, work)
              emit_box(asm, memory)
              emit_upload(asm, memory, work)
            end

            def emit_box(asm, memory)
              r = ->(n) { asm.direct(Memory.register(n)) }
              state = memory[STATE]
              asm.label("rt_background_box")
              asm.lda(r.call(0))
              asm.beq("rt_background_box_layer")
              asm.lda(LAYER_BYTES)
              asm.label("rt_background_box_layer")
              asm.tax
              # The game writes its box at every frame boundary, moved or not: the table is made
              # again in the blank only when something in it changed.
              [[1, HELD], [2, LEFT], [3, TOP], [4, RIGHT], [5, BOTTOM]].each do |n, at|
                asm.lda(r.call(n))
                asm.cmp(asm.abs_x(state + at))
                asm.bne("rt_background_box_moved")
              end
              asm.rtl
              asm.label("rt_background_box_moved")
              [[1, HELD], [2, LEFT], [3, TOP], [4, RIGHT], [5, BOTTOM]].each do |n, at|
                asm.lda(r.call(n))
                asm.sta(asm.abs_x(state + at))
              end
              asm.lda(1)
              asm.sta(asm.abs(state + CHANGED))
              asm.rtl
            end

            # rt_background_box_upload: where a box changed, each layer's table, its channel and the
            # windows' registers. +work+: the layer's table's place, the step's lines left, and the
            # two edges of the step being written (a byte each).
            def emit_upload(asm, memory, work)
              h = Console::SNESHardware
              state = memory[STATE]
              channels = memory[Picture::HDMA_CHANNELS]
              asm.label("rt_background_box_upload")
              asm.lda(asm.abs(state + CHANGED))
              asm.bne("rt_background_box_upload_changed")
              asm.rts
              asm.label("rt_background_box_upload_changed")
              asm.stz(asm.abs(state + CHANGED))
              asm.stz(asm.direct(work + 6)) # the layers held, TMW's bits
              LAYERS.times { |layer| emit_layer_table(asm, memory, work, layer, state + (layer * LAYER_BYTES), channels) }
              asm.sep(0x20)
              asm.lda(WINDOWS_OUTSIDE)
              asm.sta(asm.abs(h::W12SEL))
              asm.lda(asm.direct(work + 6))
              asm.sta(asm.abs(h::TMW))
              asm.rep(0x20)
              asm.rts
            end

            # One layer's table and channel: off where the layer is not held to a box.
            def emit_layer_table(asm, memory, work, layer, box, channels)
              h = Console::SNESHardware
              tag = "rt_background_box_upload_#{layer}"
              table = memory[table(layer)]
              channel = h::DMA_BASE + (CHANNELS.fetch(layer) << 4)
              asm.lda(asm.abs(channels))
              asm.and_a(0xFFFF ^ (1 << CHANNELS.fetch(layer)))
              asm.sta(asm.abs(channels))
              asm.lda(asm.abs(box + HELD))
              asm.bne("#{tag}_held")
              asm.brl("#{tag}_done")
              asm.label("#{tag}_held")
              asm.lda(asm.direct(work + 6))
              asm.ora(1 << layer)
              asm.sta(asm.direct(work + 6))
              asm.ldx(0)
              # Above the box: an empty span.
              asm.lda(asm.abs(box + TOP))
              emit_steps(asm, table, work, "#{tag}_above") { emit_empty_edges(asm, work) }
              # The box's lines: its span, left to right less one, both inclusive. An empty box has
              # no lines (Lowering::Picture#emit_box_background gives it nought for both).
              asm.lda(asm.abs(box + BOTTOM))
              asm.sec
              asm.sbc(asm.abs(box + TOP))
              emit_steps(asm, table, work, "#{tag}_inside") do
                asm.lda(asm.abs(box + RIGHT))
                asm.dec
                asm.xba
                asm.and_a(0xFF00)
                asm.ora(asm.abs(box + LEFT))
                asm.sta(asm.direct(work + 4))
              end
              # Below it, to the bottom of the screen: a step of one line, then the table's end,
              # which holds the span to the last line.
              asm.lda(1)
              emit_steps(asm, table, work, "#{tag}_below") { emit_empty_edges(asm, work) }
              asm.sep(0x20)
              asm.stz(asm.abs_x(table))
              asm.lda(h::DMA_TO_TWO_PORTS)
              asm.sta(asm.abs(channel + h::DMAP))
              asm.lda(EDGES.fetch(layer) & 0xFF)
              asm.sta(asm.abs(channel + h::BBAD))
              asm.lda(table >> 16)
              asm.sta(asm.abs(channel + h::A1B))
              asm.rep(0x20)
              asm.lda(table & 0xFFFF)
              asm.sta(asm.abs(channel + h::A1TL))
              asm.lda(asm.abs(channels))
              asm.ora(1 << CHANNELS.fetch(layer))
              asm.sta(asm.abs(channels))
              asm.label("#{tag}_done")
            end

            def emit_empty_edges(asm, work)
              asm.lda(EMPTY_LEFT | (EMPTY_RIGHT << 8))
              asm.sta(asm.direct(work + 4))
            end

            # Steps for A lines (none for nought), each of MOST_STEP_LINES at most, at X in +table+,
            # each the two edges the block leaves at +work+ + 4 and + 5. X is moved past them.
            def emit_steps(asm, table, work, tag)
              asm.sta(asm.direct(work + 2))
              yield
              asm.label("#{tag}_step")
              asm.lda(asm.direct(work + 2))
              asm.beq("#{tag}_done")
              asm.cmp(MOST_STEP_LINES + 1)
              asm.bcc("#{tag}_last")
              asm.lda(MOST_STEP_LINES)
              asm.label("#{tag}_last")
              asm.sta(asm.direct(work))
              asm.lda(asm.direct(work + 2))
              asm.sec
              asm.sbc(asm.direct(work))
              asm.sta(asm.direct(work + 2))
              asm.sep(0x20)
              asm.lda(asm.direct(work))
              asm.sta(asm.abs_x(table))
              asm.rep(0x20)
              asm.lda(asm.direct(work + 4))
              asm.sta(asm.abs_x(table + 1))
              asm.inx
              asm.inx
              asm.inx
              asm.bra("#{tag}_step")
              asm.label("#{tag}_done")
            end
          end
        end
      end
    end
  end
end
