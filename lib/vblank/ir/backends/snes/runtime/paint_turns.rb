# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # A PAINTED SCREEN THAT TAKES TURNS between two pictures (PaintLog's, on a plain cartridge).
          #
          # A screen that blinks, or swaps one half for the other, paints on each pass what it
          # painted two passes ago. PaintLog passes over a pass that paints what the last one did,
          # but this one differs from the last, so it is made again tile by tile: half the screen
          # swapped every other pass is 448 tiles' keys, the flush of them and all 896 cells of the
          # map, three frames a pass. The console's own games keep both pictures and swap a map.
          #
          # So the screen keeps THE OTHER PICTURE, one shown before, beside the one it shows: its
          # log, the generation its tiles were readied in (Paint) and the rows they were readied in
          # (PaintLog::READIED), and its map (OTHER_MAP). The log is two halves, each pass writing
          # in one; a pass deferred (PaintLog::DEFERRED_CLEAR) that comes to differ from the last
          # pass within its first SMALL_PREFIX paintings is compared with the other picture's log
          # from there (rt_paint_try_other). A pass that matches the whole of it TAKES ITS TURN
          # (rt_paint_turn): the other picture's generation becomes the screen's, so its tiles are
          # this pass's and the last pass's are a generation gone; the two maps change places in
          # the rows where they differ (MAP_DIFFERS), sent in one copy in the blank; and the last
          # pass's picture is the other one. No tile is painted, keyed or sent.
          #
          # The other picture is shown again only as it was: each of its tiles readied since left
          # as it had it (SHARED; one painted at once, rt_paint_mark_now, or holding something else
          # is the other picture gone, OTHER_VALID), and the screen cleared to the colour it was.
          # Else the pass is made as any other. A pass that comes to differ from the last early
          # (SMALL_PREFIX) is written in the other half, its first paintings copied there, so the
          # last pass is the other picture the next pass can match; one that differs later writes
          # over the last pass's log as before, and the other picture stays the one it was.
          #
          # Generations then go back to one shown before, so a new one is the newest given out
          # and one more (NEWEST_GENERATION), never the other picture's.
          module PaintTurns
            # The paintings a pass may match the last pass by before it differs, for it to be
            # compared with the other picture or written in the other half: what comparing or
            # copying them costs is a few lines at most.
            SMALL_PREFIX = 8
            # Where this pass's half of the log starts, where the other's does and ends, and how far
            # this pass may write (PaintLog::LOG_END and LAST_PASS_END count from the log's start).
            LOG_BASE = "rt paint log base"
            OTHER_BASE = "rt paint other base"
            OTHER_END = "rt paint other end"
            LOG_LIMIT = "rt paint log limit"
            # The other picture: whether there is one (and it can be shown), whether this pass is
            # matching its log, its generation, the colour its screen was cleared to, and the rows
            # its tiles were readied in (as READIED, and its ROWS_OF).
            OTHER_VALID = "rt paint other valid"
            MATCHING_OTHER = "rt paint matching other"
            OTHER_GENERATION = "rt paint other generation"
            OTHER_CLEAR = "rt paint other clear"
            OTHER_READIED = "rt paint other readied"
            OTHER_READIED_ROWS = "rt paint other readied rows"
            # Its map, and the first and last rows of tiles where Paint::MAP_COPY may differ from
            # it; OTHER_MAP_PENDING marks that the map shown is to be kept as the other's before the pass
            # changes it (rt_paint_map_runs).
            OTHER_MAP = "rt paint other map"
            MAP_DIFFERS_FIRST = "rt paint map differs first"
            MAP_DIFFERS_LAST = "rt paint map differs last"
            OTHER_MAP_PENDING = "rt paint other map pending"
            NEWEST_GENERATION = "rt paint newest generation"
            # The bytes of the log a pass matched before it differed, and whether it differed by
            # ending (rt_paint_try_other_at_end).
            PREFIX = "rt paint prefix"
            AT_END = "rt paint at end"
            ROW_BYTES = Paint::COLUMNS * 2
            # TILES BOTH PICTURES SHOW. A wall painted on every pass is in both pictures, and the
            # pass that paints it readies its tiles in its own generation, out of the other's. Such
            # a tile is SHARED, not touched, when the pass leaves it as the other picture had it (the
            # same key, PaintLog::KEYS_COPY, checked as the pass ends): it is kept on a list, and each
            # turn puts the tiles on it in the generation shown. Each entry is the tile and its key
            # then (SHARED_ENTRY_BYTES); a pass sharing more than MOST_SHARED touches the other.
            SHARED = "rt paint shared"
            SHARED_COUNT = "rt paint shared count"
            MOST_SHARED = 96
            SHARED_ENTRY_BYTES = 8
            SHARED_KEY = "rt paint shared key"

            module_function

            # The words every log reads, taking turns or not: where this pass's half starts and how
            # far it may write (one half, the whole log, for a screen that does not take turns), and
            # the rest of what rt_paint_start sets.
            def reserve_log_halves(memory)
              [LOG_BASE, OTHER_BASE, OTHER_END, LOG_LIMIT, OTHER_VALID, MATCHING_OTHER, OTHER_GENERATION,
               OTHER_CLEAR, MAP_DIFFERS_FIRST, MAP_DIFFERS_LAST, OTHER_MAP_PENDING, NEWEST_GENERATION, PREFIX,
               AT_END, SHARED_COUNT].each do |name|
                memory.reserve(name, 2)
              end
              memory.reserve(OTHER_READIED_ROWS, 4)
              memory.reserve(SHARED_KEY, 4)
            end

            # The other picture's map, rows and shared tiles, for a screen that can take turns
            # (Lowering::Paint.takes_turns? decides which can).
            def reserve(memory)
              memory.reserve_far(OTHER_MAP, Paint::MAP_BYTES)
              memory.reserve_far(OTHER_READIED, Paint::ROWS * 4)
              memory.reserve_far(SHARED, MOST_SHARED * SHARED_ENTRY_BYTES)
            end

            # Whether #reserve kept the other picture's room: the screen takes turns when the log has
            # room for two halves too.
            def room_reserved?(memory) = memory.reserved?(OTHER_MAP)

            # Decided once the log is reserved (PaintLog.emit), when it is big enough for two halves of
            # PaintLog::LEAST_LOG_ENTRIES each: the screen takes turns. A log smaller than that is one
            # half, as before.
            TAKES_TURNS = "rt paint takes turns"

            def take_turns(memory) = memory.reserve(TAKES_TURNS, 0)

            # Whether the screen takes turns, once PaintLog.emit has decided.
            def kept?(memory) = memory.reserved?(TAKES_TURNS)

            # At power-on (after Paint's map is all the clear tile): this pass in the first half of the
            # log (rt_paint_log_halves); no other picture, and its map the same as the screen's.
            def emit_start(asm, memory)
              asm.stz(asm.abs(memory[LOG_BASE]))
              asm.lda(asm.long("rt_paint_log_halves"))
              asm.sta(asm.abs(memory[OTHER_BASE]))
              asm.lda(asm.long("rt_paint_log_halves", 2))
              asm.sta(asm.abs(memory[LOG_LIMIT]))
              [OTHER_VALID, MATCHING_OTHER, OTHER_MAP_PENDING, NEWEST_GENERATION, MAP_DIFFERS_LAST].each { |name| asm.stz(asm.abs(memory[name])) }
              asm.lda(Paint::ROWS)
              asm.sta(asm.abs(memory[MAP_DIFFERS_FIRST]))
              Paint.emit_fill_work_ram(asm, memory[OTHER_MAP], Paint::MAP_BYTES, "rt_paint_clear_cell") if room_reserved?(memory)
            end

            # The log's halves as rt_paint_log_halves: each one's bytes, and how far a pass writes in
            # one (+limit+ bytes from its start).
            def emit_halves(asm, half, limit)
              asm.label("rt_paint_log_halves")
              asm.data_words(half, limit)
            end

            def emit(asm, memory, log)
              emit_try_other(asm, memory, log)
              emit_become_other(asm, memory, log)
              emit_turn(asm, memory)
              emit_shared_note(asm, memory)
              emit_shared_checked(asm, memory)
            end

            # The halves change places: this pass's base and the other's, LAST_PASS_END and
            # OTHER_END, and the limit with them.
            def emit_halves_swapped(asm, memory)
              [[LOG_BASE, OTHER_BASE], [PaintLog::LAST_PASS_END, OTHER_END]].each do |one, other|
                asm.lda(asm.abs(memory[one]))
                asm.ldx(asm.abs(memory[other]))
                asm.sta(asm.abs(memory[other]))
                asm.stx(asm.abs(memory[one]))
              end
              asm.lda(asm.long("rt_paint_log_halves", 2))
              asm.clc
              asm.adc(asm.abs(memory[LOG_BASE]))
              asm.sta(asm.abs(memory[LOG_LIMIT]))
            end

            # rt_paint_try_other (JSR, a deferred pass's painting differing from the last pass's at
            # LOG_END): A not nought when the pass is now compared with the other picture's log from
            # the same place — there is one, the pass is within SMALL_PREFIX paintings, and the two
            # logs are the same up to here — LOG_END and LAST_PASS_END moved to its half. Uses X and Y.
            # rt_paint_try_other_at_end (JSR, a deferred pass ending short of the last pass's log): the
            # same, the other picture's log ending here too, so the pass has matched the whole of it.
            def emit_try_other(asm, memory, log)
              asm.label("rt_paint_try_other_at_end")
              asm.lda(1)
              asm.sta(asm.abs(memory[AT_END]))
              asm.bra("rt_paint_try_other_asked")
              asm.label("rt_paint_try_other")
              asm.stz(asm.abs(memory[AT_END]))
              asm.label("rt_paint_try_other_asked")
              asm.lda(asm.abs(memory[MATCHING_OTHER]))
              asm.branch_long(:bne, "rt_paint_try_other_no")
              asm.lda(asm.abs(memory[OTHER_VALID]))
              asm.branch_long(:beq, "rt_paint_try_other_no")
              asm.lda(asm.abs(memory[PaintLog::LOG_END]))
              asm.sec
              asm.sbc(asm.abs(memory[LOG_BASE]))
              asm.sta(asm.abs(memory[PREFIX]))
              asm.cmp((SMALL_PREFIX * PaintLog::ENTRY_BYTES) + 1)
              asm.branch_long(:bcs, "rt_paint_try_other_no")
              asm.clc
              asm.adc(asm.abs(memory[OTHER_BASE]))
              asm.ldx(asm.abs(memory[AT_END]))
              asm.bne("rt_paint_try_other_end_asked")
              asm.cmp(asm.abs(memory[OTHER_END]))
              asm.branch_long(:bcs, "rt_paint_try_other_no") # the other picture has no painting here
              asm.bra("rt_paint_try_other_compared")
              asm.label("rt_paint_try_other_end_asked")
              asm.cmp(asm.abs(memory[OTHER_END]))
              asm.branch_long(:bne, "rt_paint_try_other_no") # the other picture goes on, or ended before
              asm.label("rt_paint_try_other_compared")
              # The two halves' paintings the same up to here, with the data bank the log's: each
              # entry's kind, area, first numbers and hash. An entry keeps only the numbers its kind
              # is known by (the rest are whatever an older entry left), which its hash takes in, and
              # what a flush last did with it (PaintLog::ENTRY_AGAIN) is no part of the painting.
              asm.phb
              asm.sep(0x20)
              asm.lda(log >> 16)
              asm.pha
              asm.plb
              asm.rep(0x20)
              asm.ldx(asm.abs(memory[LOG_BASE]))
              asm.ldy(asm.abs(memory[OTHER_BASE]))
              asm.label("rt_paint_try_other_entry")
              asm.cpx(asm.abs(memory[PaintLog::LOG_END]))
              asm.branch_long(:bcs, "rt_paint_try_other_same")
              compared = (0...(PaintLog::ENTRY_NUMBERS + 12)).step(2).to_a + [PaintLog::ENTRY_HASH, PaintLog::ENTRY_HASH + 2]
              compared.each do |at|
                asm.lda(asm.abs_x((log & 0xFFFF) + at))
                asm.cmp(asm.abs_y((log & 0xFFFF) + at))
                asm.branch_long(:bne, "rt_paint_try_other_differs")
              end
              asm.txa
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.tax
              asm.tya
              asm.clc
              asm.adc(PaintLog::ENTRY_BYTES)
              asm.tay
              asm.brl("rt_paint_try_other_entry")
              asm.label("rt_paint_try_other_differs")
              asm.plb
              asm.label("rt_paint_try_other_no")
              asm.lda(0)
              asm.rts
              asm.label("rt_paint_try_other_same")
              asm.plb
              asm.lda(asm.abs(memory[OTHER_BASE]))
              asm.clc
              asm.adc(asm.abs(memory[PREFIX]))
              asm.sta(asm.abs(memory[PaintLog::LOG_END]))
              emit_halves_swapped(asm, memory)
              asm.lda(1)
              asm.sta(asm.abs(memory[MATCHING_OTHER]))
              asm.rts
            end

            # rt_paint_become_other (JSR, as a deferred clear is made, before the next generation):
            # the last pass kept as the other picture, if the pass is in the other half — it was
            # matching the other picture, or it differed early and its paintings so far are copied
            # there. A pass that differed later writes over the last pass's log as before. Uses X
            # and Y.
            def emit_become_other(asm, memory, log)
              readied = memory[PaintLog::READIED]
              asm.label("rt_paint_become_other")
              asm.lda(asm.abs(memory[MATCHING_OTHER]))
              asm.bne("rt_paint_become_other_kept")
              asm.lda(asm.abs(memory[PaintLog::LOG_END]))
              asm.sec
              asm.sbc(asm.abs(memory[LOG_BASE]))
              asm.sta(asm.abs(memory[PREFIX]))
              asm.cmp((SMALL_PREFIX * PaintLog::ENTRY_BYTES) + 1)
              asm.bcc("rt_paint_become_other_copy")
              asm.rts
              asm.label("rt_paint_become_other_copy")
              asm.lda(asm.abs(memory[PREFIX]))
              asm.beq("rt_paint_become_other_copied")
              asm.phb
              asm.lda(asm.abs(memory[LOG_BASE]))
              asm.clc
              asm.adc(log & 0xFFFF)
              asm.tax
              asm.lda(asm.abs(memory[OTHER_BASE]))
              asm.clc
              asm.adc(log & 0xFFFF)
              asm.tay
              asm.lda(asm.abs(memory[PREFIX]))
              asm.dec
              asm.mvn(log >> 16, log >> 16)
              asm.plb
              asm.label("rt_paint_become_other_copied")
              asm.lda(asm.abs(memory[OTHER_BASE]))
              asm.clc
              asm.adc(asm.abs(memory[PREFIX]))
              asm.sta(asm.abs(memory[PaintLog::LOG_END]))
              emit_halves_swapped(asm, memory)
              # The last pass's picture, as the screen shows it, is the other one now.
              asm.label("rt_paint_become_other_kept")
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.sta(asm.abs(memory[OTHER_GENERATION]))
              asm.lda(asm.abs(memory[Paint::CLEAR_PLACE]))
              asm.sta(asm.abs(memory[OTHER_CLEAR]))
              asm.ldx(0)
              asm.label("rt_paint_become_other_row")
              asm.lda(asm.long_x(readied))
              asm.sta(asm.long_x(memory[OTHER_READIED]))
              asm.inx
              asm.inx
              asm.cpx(Paint::ROWS * 4)
              asm.bne("rt_paint_become_other_row")
              rows = memory[PaintLog::ROWS_OF.fetch(PaintLog::READIED)]
              2.times do |half|
                asm.lda(asm.abs(rows + (half * 2)))
                asm.sta(asm.abs(memory[OTHER_READIED_ROWS] + (half * 2)))
              end
              asm.stz(asm.abs(memory[SHARED_COUNT]))
              asm.stz(asm.abs(memory[MATCHING_OTHER]))
              asm.lda(1)
              asm.sta(asm.abs(memory[OTHER_VALID]))
              asm.sta(asm.abs(memory[OTHER_MAP_PENDING]))
              asm.rts
            end

            # rt_paint_turn (JSR, as a deferred pass ends having matched the whole of the other
            # picture's log, which it may show): the other picture shown, the last pass's kept as
            # the other (see the top). Uses X and Y.
            def emit_turn(asm, memory)
              map = memory[Paint::MAP_COPY]
              other_map = memory[OTHER_MAP]
              readied = memory[PaintLog::READIED]
              asm.label("rt_paint_turn")
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.ldx(asm.abs(memory[OTHER_GENERATION]))
              asm.sta(asm.abs(memory[OTHER_GENERATION]))
              asm.stx(asm.abs(memory[Paint::GENERATION]))
              emit_shared_shown(asm, memory)
              asm.ldx(0)
              asm.label("rt_paint_turn_readied")
              asm.lda(asm.long_x(readied))
              asm.tay
              asm.lda(asm.long_x(memory[OTHER_READIED]))
              asm.sta(asm.long_x(readied))
              asm.tya
              asm.sta(asm.long_x(memory[OTHER_READIED]))
              asm.inx
              asm.inx
              asm.cpx(Paint::ROWS * 4)
              asm.bne("rt_paint_turn_readied")
              rows = memory[PaintLog::ROWS_OF.fetch(PaintLog::READIED)]
              2.times do |half|
                asm.lda(asm.abs(rows + (half * 2)))
                asm.ldx(asm.abs(memory[OTHER_READIED_ROWS] + (half * 2)))
                asm.sta(asm.abs(memory[OTHER_READIED_ROWS] + (half * 2)))
                asm.stx(asm.abs(rows + (half * 2)))
              end
              # The maps' rows that differ change places, a row of 32 cells at a time, and go to
              # video RAM in one copy (PaintLog's map runs, which the blank sends with the rest).
              asm.lda(asm.abs(memory[MAP_DIFFERS_LAST]))
              asm.cmp(asm.abs(memory[MAP_DIFFERS_FIRST]))
              asm.branch_long(:bcc, "rt_paint_turn_mapped")
              asm.inc
              asm.xba
              asm.lsr
              asm.lsr # 64 bytes a row
              asm.sta(asm.abs(memory[PREFIX])) # the end
              asm.lda(asm.abs(memory[MAP_DIFFERS_FIRST]))
              asm.xba
              asm.lsr
              asm.lsr
              asm.tax
              asm.label("rt_paint_turn_row")
              Paint::COLUMNS.times do |cell|
                asm.lda(asm.long_x(map, cell * 2))
                asm.tay
                asm.lda(asm.long_x(other_map, cell * 2))
                asm.sta(asm.long_x(map, cell * 2))
                asm.tya
                asm.sta(asm.long_x(other_map, cell * 2))
              end
              asm.txa
              asm.clc
              asm.adc(ROW_BYTES)
              asm.tax
              asm.cpx(asm.abs(memory[PREFIX]))
              asm.branch_long(:bne, "rt_paint_turn_row")
              runs = memory[PaintLog::MAP_RUNS]
              asm.lda(asm.abs(memory[MAP_DIFFERS_FIRST]))
              5.times { asm.asl } # its first cell
              asm.sta(asm.long(runs))
              asm.lda(asm.abs(memory[MAP_DIFFERS_LAST]))
              asm.sec
              asm.sbc(asm.abs(memory[MAP_DIFFERS_FIRST]))
              asm.inc
              5.times { asm.asl } # its cells
              asm.sta(asm.long(runs + 2))
              asm.asl
              asm.clc
              asm.adc(Paint::RUN_SETTING_UP)
              asm.sta(asm.abs(memory[PaintLog::MAP_RUN_BYTES]))
              asm.lda(4)
              asm.sta(asm.abs(memory[PaintLog::MAP_RUNS_END]))
              asm.label("rt_paint_turn_mapped")
              asm.jsr(asm.abs("rt_paint_layer_rebuild")) if TextLayer.kept?(memory)
              asm.stz(asm.abs(memory[MATCHING_OTHER]))
              asm.lda(asm.abs(memory[Paint::CLEAR_PLACE]))
              asm.sta(asm.abs(memory[OTHER_CLEAR]))
              asm.rts
            end

            # In a routine painting at once readying a tile, A its generation till now (16 bits): the
            # other picture gone if that is its. A changes.
            def emit_touched_check(asm, memory, tag)
              asm.cmp(asm.abs(memory[OTHER_GENERATION]))
              asm.bne("#{tag}_other_untouched")
              asm.stz(asm.abs(memory[OTHER_VALID]))
              asm.label("#{tag}_other_untouched")
            end

            # In PaintLog's rt_paint_mark, readying the tile in Y (its keys at X, four bytes a tile),
            # A its generation till now: a tile of the other picture's noted (rt_paint_shared_note).
            # A changes; X and Y are kept.
            def emit_shared_noted(asm, memory, tag)
              asm.cmp(asm.abs(memory[OTHER_GENERATION]))
              asm.bne("#{tag}_not_shared")
              asm.jsr(asm.abs("rt_paint_shared_note"))
              asm.label("#{tag}_not_shared")
            end

            # rt_paint_shared_note (JSR, as emit_shared_noted): the tile put on the SHARED list with
            # the key of what the copy holds; the other picture gone when the list is full, and
            # nothing more noted once it is.
            def emit_shared_note(asm, memory)
              keys = memory[PaintLog::KEYS_COPY]
              asm.label("rt_paint_shared_note")
              asm.lda(asm.abs(memory[OTHER_VALID]))
              asm.beq("rt_paint_shared_note_gone")
              asm.lda(asm.abs(memory[SHARED_COUNT]))
              asm.cmp(MOST_SHARED)
              asm.bcc("rt_paint_shared_note_room")
              asm.stz(asm.abs(memory[OTHER_VALID]))
              asm.label("rt_paint_shared_note_gone")
              asm.rts
              asm.label("rt_paint_shared_note_room")
              2.times do |half|
                asm.lda(asm.long_x(keys, half * 2))
                asm.sta(asm.abs(memory[SHARED_KEY] + (half * 2)))
              end
              asm.phx
              asm.lda(asm.abs(memory[SHARED_COUNT]))
              3.times { asm.asl }
              asm.tax
              asm.tya
              asm.sta(asm.long_x(memory[SHARED]))
              2.times do |half|
                asm.lda(asm.abs(memory[SHARED_KEY] + (half * 2)))
                asm.sta(asm.long_x(memory[SHARED], 2 + (half * 2)))
              end
              asm.inc(asm.abs(memory[SHARED_COUNT]))
              asm.plx
              asm.rts
            end

            # rt_paint_shared_checked (JSR, as a pass ends, after its flush): the other picture gone if
            # a tile on the SHARED list holds something else now than it had there. Uses X and Y.
            def emit_shared_checked(asm, memory)
              keys = memory[PaintLog::KEYS_COPY]
              asm.label("rt_paint_shared_checked")
              asm.lda(asm.abs(memory[OTHER_VALID]))
              asm.beq("rt_paint_shared_checked_done")
              asm.ldy(0)
              asm.label("rt_paint_shared_checked_entry")
              asm.tya
              asm.lsr
              asm.lsr
              asm.lsr
              asm.cmp(asm.abs(memory[SHARED_COUNT]))
              asm.bcs("rt_paint_shared_checked_done")
              asm.tyx
              asm.lda(asm.long_x(memory[SHARED]))
              asm.asl
              asm.asl
              asm.tax # the tile's keys
              2.times do |half|
                asm.lda(asm.long_x(keys, half * 2))
                asm.sta(asm.abs(memory[SHARED_KEY] + (half * 2)))
              end
              asm.tyx
              2.times do |half|
                asm.lda(asm.long_x(memory[SHARED], 2 + (half * 2)))
                asm.cmp(asm.abs(memory[SHARED_KEY] + (half * 2)))
                asm.bne("rt_paint_shared_checked_changed")
              end
              asm.tya
              asm.clc
              asm.adc(SHARED_ENTRY_BYTES)
              asm.tay
              asm.bra("rt_paint_shared_checked_entry")
              asm.label("rt_paint_shared_checked_changed")
              asm.stz(asm.abs(memory[OTHER_VALID]))
              asm.label("rt_paint_shared_checked_done")
              asm.rts
            end

            # In rt_paint_turn: each tile on the SHARED list put in the generation now shown, as a
            # tile of this picture's. Uses X and Y.
            def emit_shared_shown(asm, memory)
              asm.ldy(0)
              asm.label("rt_paint_turn_shared")
              asm.tya
              asm.lsr
              asm.lsr
              asm.lsr
              asm.cmp(asm.abs(memory[SHARED_COUNT]))
              asm.bcs("rt_paint_turn_shared_done")
              asm.tyx
              asm.lda(asm.long_x(memory[SHARED]))
              asm.tax
              asm.sep(0x20)
              asm.lda(asm.abs(memory[Paint::GENERATION]))
              asm.sta(asm.long_x(memory[Paint::GENERATIONS]))
              asm.sta(asm.long_x(memory[PaintLog::PAINTED_IN]))
              asm.rep(0x20)
              asm.tya
              asm.clc
              asm.adc(SHARED_ENTRY_BYTES)
              asm.tay
              asm.bra("rt_paint_turn_shared")
              asm.label("rt_paint_turn_shared_done")
            end
          end
        end
      end
    end
  end
end
