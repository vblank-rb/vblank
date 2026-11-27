# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # The sound effects played on a driver's wakes, for a game whose sound driver has a habit
          # the plain frame of the effects cannot follow (Audio::SoundDriver): it keys an effect only
          # on a tick (`effects_start: :on_next_tick`), it skips its tick while the music is silent
          # (`silent_music_stops_ticks: true`), or the game sends a request at a screen row
          # (`sent_after_rows:`). A game with none of these plays its effects as Music#emit_frames
          # does, with not a byte changed.
          #
          # ### The wakes and the ticks
          #
          # A retail sound driver runs on the SPC700, woken by its timer 0 (fullsnes, "SNES APU
          # SPC700 I/O Ports", $FA and $FD), and on each wake adds its tempo to a count; a tick is a
          # wake whose count comes round. Here the console's processor decides each frame's sound,
          # as every other part of this runtime does, and the sound unit strikes each tick's notes at
          # the tick's place in the frame (Strikes). So the frame first counts its wakes, as
          # Reference::Player#count_ticks_on_interrupts does: which of them hold a tick, and where in
          # the frame each tick falls (TICK_WAKES, TICK_OFFSETS). Then each effect asked for is given
          # the wake it starts on (#emit_take_up), and the frame is walked a tick at a time, an effect
          # starting just before the walk of the first tick on or after its wake
          # (Reference::Player#play_effects_on_wakes).
          #
          # ### A request at a row
          #
          # A retail game writes a sound request to the APU's ports while its pass runs, at whatever
          # screen row the pass has reached (fullsnes, "SNES APU Main CPU Communication Port"), and the
          # driver reads the port on its next wake. The pass that asks runs in the frame its own end
          # takes the request up in, so the request lands that many rows into the frame: the build
          # works out how far, as a share of the frame's wakes (IR::Tunes.row_share), and the frame
          # starts the effect on the first wake past it. Two requests before one wake leave the port
          # holding the last, so of those the one at the later row is kept (rt_sfx_play_at_row). A song
          # named at a row sets the effects' count on the first wake past it, where its start sets one.
          #
          # ### What it costs
          #
          # A frame counts its wakes once into the two lists, a few instructions a wake, and walks the
          # live effects once more to give each asked for its wake. A later tick that starts an effect
          # walks them once more, as the tick it starts on does already.
          module DriverWakes
            # The habits named, each true or false: +starts_on_tick+, +silent_stops_ticks+, +effect_rows+
            # (an effect asked for at a row) and +song_rows+ (a song).
            Habits = Data.define(:starts_on_tick, :silent_stops_ticks, :effect_rows, :song_rows) do
              # The habits +program+ names, or nil for none, or for effects not on a driver's wakes.
              def self.of(program)
                return unless IR::Tunes.effect_tempo_step(program) && IR::Tunes.effects(program).any?

                rows = program.walk.select { |node| IR::Tunes::ROW_REQUESTS.include?(node.kind) && node.sent_after_rows }
                habits = new(starts_on_tick: IR::Tunes.effects_start_on_tick?(program),
                             silent_stops_ticks: IR::Tunes.silent_music_stops_ticks?(program),
                             effect_rows: rows.any? { |node| node.kind == :play_sound_effect },
                             song_rows: rows.any? { |node| node.kind != :play_sound_effect })
                habits if habits.to_h.values.any?
              end
            end

            # The frame's wakes: how many held a tick, two bytes each (TICK_END); the wake each tick
            # is on, counted from 1; where in the frame each falls (Strikes::OFFSET's units); the wake
            # being counted; and the song whose tempo the count adds on it.
            TICK_END = "rt sfx tick end"
            TICK_WAKES = "rt sfx tick wakes"
            TICK_OFFSETS = "rt sfx tick offsets"
            WAKE = "rt sfx wake"
            TUNE_COUNTED = "rt sfx tune counted"
            # The walk: which tick is playing, two bytes each, and what an effect joining at it holds
            # in JOIN (Effects); and, while an effect is given its wake, the wake asked from, whether it
            # was asked with no row, and the wake it starts on.
            ORDINAL_AT = "rt sfx ordinal at"
            JOIN_NOW = "rt sfx join now"
            # ...whether any effect joins at each tick, and past the last, a word each, so a tick that
            # starts nothing needs no walk to start it.
            JOINED = "rt sfx joined"
            ASKED_WAKE = "rt sfx asked wake"
            ASKED_PLAINLY = "rt sfx asked plainly"
            START_WAKE = "rt sfx start wake"
            # The effects asked for at a row this pass, ROW_BYTES each, ROWS_MOST at most: the wake
            # its row comes before, the place asked for (R0's two words), the list (R1) and the share
            # (R2's two words); where the list ends; and where a frame's take-up reads it.
            ROWS = "rt sfx rows"
            ROW_END = "rt sfx row end"
            ROW_AT = "rt sfx row at"
            ROW_BYTES = 12
            ROWS_MOST = 16 # One more, at another wake, is not heard: no pass asks at so many
            # A song named at a row: the song, nought for none, and its share; the song, the count and
            # its share as the frame began; the clock then; the wake the song is picked up on, nought
            # for none this frame; and whether its start still owes the count it sets, past the frame.
            SONG_AT_ROW = "rt music song at row"
            SONG_ROW_SHARE = "rt music song row share"
            SONG_BEFORE = "rt music song before"
            COUNT_BEFORE = "rt sfx count before"
            NOW_BEFORE = "rt sfx now before"
            FRAME_CLOCK_START = "rt sfx frame clock start"
            CHANGE_WAKE = "rt sfx change wake"
            COUNT_OWED = "rt sfx count owed"

            module_function

            # +most_wakes+ is the most a frame has (IR::Tunes.most_ticks_a_frame); +count_at_song_start+
            # is where a song's start sets the count, or nil.
            def reserve(memory, habits, most_wakes:, count_at_song_start:)
              [TICK_END, WAKE, TUNE_COUNTED, ORDINAL_AT, JOIN_NOW, ASKED_WAKE, ASKED_PLAINLY, START_WAKE].each { |name| memory.reserve(name, 2) }
              [TICK_WAKES, TICK_OFFSETS].each { |name| memory.reserve(name, most_wakes * 2) }
              memory.reserve(JOINED, (most_wakes + 1) * 2)
              if habits.effect_rows
                [ROW_END, ROW_AT].each { |name| memory.reserve(name, 2) }
                memory.reserve(ROWS, ROWS_MOST * ROW_BYTES)
              end
              return unless habits.song_rows

              [SONG_AT_ROW, SONG_BEFORE, COUNT_BEFORE, NOW_BEFORE, FRAME_CLOCK_START, CHANGE_WAKE].each { |name| memory.reserve(name, 2) }
              memory.reserve(SONG_ROW_SHARE, 4)
              memory.reserve(COUNT_OWED, 2) if count_at_song_start
            end

            # Whether the effects here play on a driver's wakes.
            def on_wakes?(memory) = memory.reserved?(TICK_END)

            # rt_music_frame for a game whose effects play on a driver's wakes (Music#emit_frames' order:
            # the tune caught up with, the effects that outrank it, its parts, the other effects). +step+
            # is the clock's step, +tempo+ the tempo's (:tune for the song playing's), +level_at+ where the
            # game keeps its music volume, or nil.
            def emit_frame(asm, at, memory, step:, tempo:, habits:, level_at:, count_at_song_start:)
              song_rows = memory.reserved?(SONG_AT_ROW)
              asm.label("rt_music_frame")
              emit_kept_before_switch(asm, at, memory) if song_rows
              asm.jsr(asm.abs("rt_music_switch"))
              asm.jsl(asm.long("rt_strikes_mark"))
              Strikes.emit_first_offset(asm, memory, Music::EFFECT_CLOCK, step)
              if song_rows
                asm.lda(at.call(Music::EFFECT_CLOCK))
                asm.sta(at.call(FRAME_CLOCK_START))
              end
              Music.emit_step_effect_clock(asm, at, step)
              asm.lda(at.call(Music::EFFECT_TICKED)) # the frame's first wake's place, the frame's start where it has none
              asm.bne("rt_sfx_wakes_some")
              asm.stz(at.call(Strikes::OFFSET))
              asm.label("rt_sfx_wakes_some")
              asm.lda(at.call(Strikes::OFFSET))
              asm.sta(at.call(Strikes::START_OFFSET))
              asm.jsr(asm.abs("rt_sfx_count_wakes"))
              asm.jsr(asm.abs("rt_sfx_take_up"))
              emit_first_walk(asm, at, habits)
              emit_later_walks(asm, at, memory)
              Music.emit_frame_end(asm, memory, strikes: true)
              emit_count_wakes(asm, at, memory, step: step, tempo: tempo, level_at: (level_at if habits.silent_stops_ticks),
                                                count_at_song_start: count_at_song_start)
              emit_take_up(asm, at, memory, habits, step)
              emit_song_change_wake(asm, at, count_at_song_start) if song_rows
              emit_play_at_row(asm, at, memory) if habits.effect_rows
              emit_song_at_row(asm, at) if song_rows
            end

            # The song, the count and its share as the frame begins, before a song's start sets them.
            def emit_kept_before_switch(asm, at, memory)
              asm.lda(at.call(Music::PLAYING))
              asm.sta(at.call(SONG_BEFORE))
              asm.lda(at.call(Music::EFFECT_TEMPO))
              asm.sta(at.call(COUNT_BEFORE))
              return unless memory.reserved?(Music::TEMPO_NOW)

              asm.lda(at.call(Music::TEMPO_NOW))
              asm.sta(at.call(NOW_BEFORE))
            end

            # The first tick's walk, around the tune: on each side, what joins before the first tick
            # starts, struck at the frame's first wake (at the tick, for a driver that keys effects only
            # on one), and then on a frame with a tick every effect moves on, struck at the tick.
            def emit_first_walk(asm, at, habits)
              asm.stz(at.call(ORDINAL_AT))
              asm.lda(2)
              asm.sta(at.call(JOIN_NOW))
              starting = habits.starts_on_tick ? at.call(TICK_OFFSETS) : at.call(Strikes::START_OFFSET)
              emit_starting_pass(asm, at, "rt_sfx_above", starting)
              emit_tick_pass(asm, at, "rt_sfx_above")
              asm.lda(at.call(Music::PLAYING))
              asm.beq("rt_music_frame_played")
              asm.jsr(asm.abs("rt_music_song_frame"))
              asm.label("rt_music_frame_played")
              emit_starting_pass(asm, at, "rt_sfx_below", starting)
              emit_tick_pass(asm, at, "rt_sfx_below")
            end

            # Each later tick: what joins at it starts, every effect by rank, and then every effect
            # moves on, both struck at the tick; and after the last tick, what joins past it starts.
            def emit_later_walks(asm, at, memory)
              asm.label("rt_sfx_later_walk")
              asm.lda(at.call(ORDINAL_AT))
              asm.inc
              asm.inc
              asm.sta(at.call(ORDINAL_AT))
              asm.cmp(at.call(TICK_END))
              asm.branch_long(:bcs, "rt_sfx_later_walks_done")
              asm.inc(at.call(JOIN_NOW))
              asm.inc(at.call(JOIN_NOW))
              asm.ldx(at.call(ORDINAL_AT))
              asm.lda(asm.abs_x(memory[TICK_OFFSETS]))
              asm.sta(at.call(Strikes::OFFSET))
              asm.lda(asm.abs_x(memory[JOINED])) # nothing joins at most ticks: no walk to start it
              asm.beq("rt_sfx_later_none_join")
              emit_starting_walk(asm, at)
              asm.label("rt_sfx_later_none_join")
              asm.jsr(asm.abs("rt_sfx_above"))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.jsr(asm.abs("rt_sfx_below"))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.brl("rt_sfx_later_walk")
              asm.label("rt_sfx_later_walks_done")
              asm.lda(at.call(TICK_END))
              asm.beq("rt_sfx_past_last_done")
              asm.tax
              asm.lda(asm.abs_x(memory[JOINED]))
              asm.beq("rt_sfx_past_last_done")
              asm.txa
              asm.inc
              asm.inc
              asm.sta(at.call(JOIN_NOW))
              asm.lda(asm.abs_x(memory[TICK_OFFSETS], -2)) # the last tick's place
              asm.sta(at.call(Strikes::OFFSET))
              emit_starting_walk(asm, at)
              asm.label("rt_sfx_past_last_done")
            end

            # A starting pass on both sides of the tune, in rank order, at Strikes::OFFSET as it stands.
            def emit_starting_walk(asm, at)
              asm.lda(1)
              asm.sta(at.call(Music::EFFECTS_STARTING))
              asm.jsr(asm.abs("rt_sfx_above"))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.jsr(asm.abs("rt_sfx_below"))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.stz(at.call(Music::EFFECTS_STARTING))
            end

            # +routine+ as a pass that starts what joins at the tick playing, struck at +offset+.
            def emit_starting_pass(asm, at, routine, offset)
              asm.lda(1)
              asm.sta(at.call(Music::EFFECTS_STARTING))
              asm.lda(offset)
              asm.sta(at.call(Strikes::OFFSET))
              asm.jsr(asm.abs(routine))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.stz(at.call(Music::EFFECTS_STARTING))
            end

            # ...and as the first tick's pass, on a frame with one.
            def emit_tick_pass(asm, at, routine)
              asm.lda(at.call(TICK_END))
              asm.beq(skipped = "#{routine}_no_tick")
              asm.lda(at.call(TICK_OFFSETS))
              asm.sta(at.call(Strikes::OFFSET))
              asm.jsr(asm.abs(routine))
              asm.jsl(asm.long("rt_strikes_close"))
              asm.label(skipped)
            end

            # rt_sfx_count_wakes: the frame's wakes (Music::EFFECT_TICKED of them) counted into TICK_WAKES
            # and TICK_OFFSETS (Reference::Player#count_ticks_on_interrupts). Each wake adds the tempo's
            # step to the count, or after a song's start the share it set (Music::TEMPO_NOW); a song
            # named at a row is counted from its wake, the wakes before it as the song before had
            # them. With +level_at+, a wake adds nothing while the music volume is nought.
            def emit_count_wakes(asm, at, memory, step:, tempo:, level_at:, count_at_song_start:)
              song_rows = memory.reserved?(SONG_AT_ROW)
              asm.label("rt_sfx_count_wakes")
              asm.stz(at.call(TICK_END))
              asm.stz(at.call(WAKE))
              asm.lda(at.call(Music::PLAYING))
              asm.sta(at.call(TUNE_COUNTED))
              if song_rows
                asm.jsr(asm.abs("rt_sfx_song_change_wake"))
                asm.beq("rt_sfx_wake_next")
                asm.lda(at.call(COUNT_BEFORE))
                asm.sta(at.call(Music::EFFECT_TEMPO))
                if memory.reserved?(Music::TEMPO_NOW)
                  asm.lda(at.call(NOW_BEFORE))
                  asm.sta(at.call(Music::TEMPO_NOW))
                end
                asm.lda(at.call(SONG_BEFORE))
                asm.sta(at.call(TUNE_COUNTED))
              end
              asm.label("rt_sfx_wake_next")
              asm.lda(at.call(WAKE))
              asm.cmp(at.call(Music::EFFECT_TICKED))
              asm.branch_long(:bcs, "rt_sfx_wakes_counted")
              asm.inc(at.call(WAKE))
              emit_song_picked_up(asm, at, count_at_song_start) if song_rows
              if level_at
                asm.lda(asm.abs(level_at))
                asm.beq("rt_sfx_wake_counted")
              end
              emit_step(asm, at, memory, tempo, step)
              asm.bcc("rt_sfx_wake_counted")
              asm.ldx(at.call(TICK_END))
              asm.lda(at.call(WAKE))
              asm.sta(asm.abs_x(memory[TICK_WAKES]))
              asm.lda(at.call(Strikes::OFFSET))
              asm.sta(asm.abs_x(memory[TICK_OFFSETS]))
              asm.inc(at.call(TICK_END))
              asm.inc(at.call(TICK_END))
              asm.label("rt_sfx_wake_counted")
              Strikes.emit_next_offset(asm, memory, step)
              asm.brl("rt_sfx_wake_next")
              asm.label("rt_sfx_wakes_counted")
              if song_rows && count_at_song_start # a song picked up past the frame's last wake owes its count
                asm.lda(at.call(Music::EFFECT_TICKED))
                asm.cmp(at.call(CHANGE_WAKE))
                asm.bcs("rt_sfx_wakes_owed")
                asm.lda(1)
                asm.sta(at.call(COUNT_OWED))
                asm.label("rt_sfx_wakes_owed")
              end
              asm.rts
            end

            # On the wake a song named at a row is picked up on: the count from there is the song's, set
            # where its start sets one.
            def emit_song_picked_up(asm, at, count_at_song_start)
              asm.lda(at.call(WAKE))
              asm.cmp(at.call(CHANGE_WAKE))
              asm.bne("rt_sfx_wake_same_song")
              asm.lda(at.call(Music::PLAYING))
              asm.sta(at.call(TUNE_COUNTED))
              Music.emit_tick_count_at_song_start(asm, at, count_at_song_start) if count_at_song_start
              asm.label("rt_sfx_wake_same_song")
            end

            # A wake's step of the count, inline, the carry set where it comes round: a tick
            # (Music#emit_step_effect_tempo, the song's tempo read for TUNE_COUNTED). Uses X.
            def emit_step(asm, at, memory, tempo, step)
              unless memory.reserved?(Music::TEMPO_NOW)
                asm.lda(at.call(Music::EFFECT_TEMPO))
                asm.clc
                asm.adc(tempo)
                asm.sta(at.call(Music::EFFECT_TEMPO))
                return
              end

              asm.lda(at.call(Music::TEMPO_NOW))
              asm.bne("rt_sfx_wake_stepped")
              if tempo == :tune
                asm.lda(at.call(TUNE_COUNTED))
                asm.asl
                asm.tax
                asm.lda(asm.long_x("tune_tempo_steps"))
              else
                asm.lda(tempo)
              end
              asm.label("rt_sfx_wake_stepped")
              asm.clc
              asm.adc(at.call(Music::EFFECT_TEMPO))
              asm.sta(at.call(Music::EFFECT_TEMPO))
              asm.bcc("rt_sfx_wake_kept")
              asm.stz(at.call(Music::TEMPO_NOW)) # STZ leaves the carry
              asm.label("rt_sfx_wake_kept")
            end

            # rt_sfx_take_up: each effect asked for given the wake it starts on this frame
            # (Reference::Player#effect_starts_on_wakes), as JOIN, the tick before whose walk it starts
            # (two bytes a tick, from 2), and ON_TICK, whether that wake holds the tick. One asked for
            # with no row is asked from the frame's first wake; one at a row is asked for here, from the
            # wake past it. One whose wake is past the frame's stays asked for, for the next frame.
            def emit_take_up(asm, at, memory, habits, step)
              state = ->(field) { asm.abs_y(memory[Effects::STATES], field) }
              asm.label("rt_sfx_take_up")
              (0..IR::Tunes.most_ticks_a_frame(step)).each { |tick| asm.stz(at.call(JOINED, tick * 2)) }
              if habits.effect_rows # which were asked for with no row, before the rows are
                Effects.emit_live_walk(asm, at, memory, "rt_sfx_plain") do
                  asm.lda(state.call(Effects::ASKED))
                  asm.sta(state.call(Effects::PLAIN))
                  asm.lda(0)
                  asm.sta(state.call(Effects::ROW_WAKE))
                end
                emit_rows_asked(asm, at, memory)
              end
              Effects.emit_live_walk(asm, at, memory, "rt_sfx_starts") do
                asm.lda(0)
                asm.sta(state.call(Effects::JOIN))
                asm.sta(state.call(Effects::ON_TICK))
                asm.lda(state.call(Effects::ASKED))
                asm.branch_long(:beq, "rt_sfx_starts_walk")
                if habits.effect_rows
                  asm.lda(state.call(Effects::PLAIN))
                  asm.sta(at.call(ASKED_PLAINLY))
                  asm.beq("rt_sfx_starts_row")
                  asm.lda(1)
                  asm.bra("rt_sfx_starts_from")
                  asm.label("rt_sfx_starts_row")
                  asm.lda(state.call(Effects::ROW_WAKE))
                  asm.label("rt_sfx_starts_from")
                else
                  asm.lda(1)
                  asm.sta(at.call(ASKED_PLAINLY))
                end
                asm.sta(at.call(ASKED_WAKE))
                emit_starting_wake(asm, at, memory, habits)
                asm.branch_long(:beq, "rt_sfx_starts_walk") # waits for the next frame
                asm.sta(at.call(START_WAKE))
                asm.ldy(at.call(Effects::STATE))
                asm.lda(0)
                asm.sta(state.call(Effects::ASKED))
                emit_join(asm, at, memory)
                asm.lda(1)
                asm.sta(asm.abs_x(memory[JOINED]))
                asm.txa
                asm.inc
                asm.inc
                asm.sta(state.call(Effects::JOIN))
                asm.cpx(at.call(TICK_END)) # the first tick on or after its wake is on that wake
                asm.bcs("rt_sfx_starts_walk")
                asm.lda(asm.abs_x(memory[TICK_WAKES]))
                asm.cmp(at.call(START_WAKE))
                asm.bne("rt_sfx_starts_walk")
                asm.lda(1)
                asm.sta(state.call(Effects::ON_TICK))
                asm.label("rt_sfx_starts_walk")
              end
              asm.rts
            end

            # The effects asked for at a row this pass, each asked for now (rt_sfx_request), its wake
            # kept in ROW_WAKE where it was.
            def emit_rows_asked(asm, at, memory)
              asm.stz(at.call(ROW_AT))
              asm.label("rt_sfx_rows_next")
              asm.ldx(at.call(ROW_AT))
              asm.cpx(at.call(ROW_END))
              asm.branch_long(:bcs, "rt_sfx_rows_done")
              asm.lda(asm.abs_x(memory[ROWS], 2))
              asm.sta(asm.direct(Sound::R0))
              asm.lda(asm.abs_x(memory[ROWS], 4))
              asm.sta(asm.direct(Sound::R0 + 2))
              asm.lda(asm.abs_x(memory[ROWS], 6))
              asm.sta(asm.direct(Sound::R1))
              asm.jsr(asm.abs("rt_sfx_request"))
              asm.beq("rt_sfx_rows_refused")
              asm.lda(at.call(Effects::ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.ldx(at.call(ROW_AT))
              asm.lda(asm.abs_x(memory[ROWS]))
              asm.sta(asm.abs_y(memory[Effects::STATES], Effects::ROW_WAKE))
              asm.label("rt_sfx_rows_refused")
              asm.lda(at.call(ROW_AT))
              asm.clc
              asm.adc(ROW_BYTES)
              asm.sta(at.call(ROW_AT))
              asm.brl("rt_sfx_rows_next")
              asm.label("rt_sfx_rows_done")
              asm.stz(at.call(ROW_END))
            end

            # The wake an effect asked from ASKED_WAKE starts on, in A, nought to wait for the next frame,
            # inline (Reference::Player#starting_wake): the first wake from there holding a tick, for a
            # driver that keys an effect only on one; else that wake, where the frame has it, or the
            # first wake for one asked with no row, even in a frame with none. Uses X.
            def emit_starting_wake(asm, at, memory, habits)
              if habits.starts_on_tick
                asm.ldx(0)
                asm.label("rt_sfx_starting_next")
                asm.cpx(at.call(TICK_END))
                asm.bcs("rt_sfx_starting_none")
                asm.lda(asm.abs_x(memory[TICK_WAKES]))
                asm.cmp(at.call(ASKED_WAKE))
                asm.bcs("rt_sfx_starting_tick")
                asm.inx
                asm.inx
                asm.bra("rt_sfx_starting_next")
                asm.label("rt_sfx_starting_tick")
                asm.lda(asm.abs_x(memory[TICK_WAKES])) # again, for the zero flag the compare spent
                asm.bra("rt_sfx_starting_found")
                asm.label("rt_sfx_starting_none")
                asm.lda(0)
                asm.label("rt_sfx_starting_found")
                return
              end

              asm.lda(at.call(Music::EFFECT_TICKED))
              asm.cmp(at.call(ASKED_WAKE))
              asm.bcs("rt_sfx_starting_in_frame")
              asm.lda(at.call(ASKED_PLAINLY)) # a plain ask is from wake 1, so the frame has no wake
              asm.beq("rt_sfx_starting_found")
              asm.label("rt_sfx_starting_in_frame")
              asm.lda(at.call(ASKED_WAKE))
              asm.label("rt_sfx_starting_found")
            end

            # X, the ticks before START_WAKE, two bytes each: the tick an effect starting there joins.
            def emit_join(asm, at, memory)
              asm.ldx(0)
              asm.label("rt_sfx_join_next")
              asm.cpx(at.call(TICK_END))
              asm.bcs("rt_sfx_join_found")
              asm.lda(asm.abs_x(memory[TICK_WAKES]))
              asm.cmp(at.call(START_WAKE))
              asm.bcs("rt_sfx_join_found")
              asm.inx
              asm.inx
              asm.bra("rt_sfx_join_next")
              asm.label("rt_sfx_join_found")
            end

            # rt_sfx_song_change_wake: CHANGE_WAKE and A, the wake a song named at a row this pass is
            # picked up on, nought for a frame whose song changed with no row, or not at all. A count the
            # song's start still owes from the frame before is set first (Reference::Player#song_change_wake).
            def emit_song_change_wake(asm, at, count_at_song_start)
              asm.label("rt_sfx_song_change_wake")
              if count_at_song_start
                asm.lda(at.call(COUNT_OWED))
                asm.beq("rt_sfx_change_none_owed")
                asm.stz(at.call(COUNT_OWED))
                asm.lda(at.call(Music::PLAYING))
                asm.beq("rt_sfx_change_none_owed")
                Music.emit_tick_count_at_song_start(asm, at, count_at_song_start)
                asm.label("rt_sfx_change_none_owed")
              end
              asm.stz(at.call(CHANGE_WAKE))
              asm.lda(at.call(SONG_AT_ROW))
              asm.stz(at.call(SONG_AT_ROW))
              asm.beq("rt_sfx_change_done")
              asm.cmp(at.call(Music::PLAYING))
              asm.bne("rt_sfx_change_done")
              asm.cmp(at.call(SONG_BEFORE))
              asm.beq("rt_sfx_change_done")
              asm.lda(at.call(FRAME_CLOCK_START))
              asm.clc
              asm.adc(at.call(SONG_ROW_SHARE))
              asm.lda(at.call(SONG_ROW_SHARE, 2)) # LDA leaves the carry
              asm.adc(1)
              asm.sta(at.call(CHANGE_WAKE))
              asm.label("rt_sfx_change_done")
              asm.lda(at.call(CHANGE_WAKE))
              asm.rts
            end

            # rt_sfx_play_at_row(which, list, share): the effect at place +which+ of effect list +list+
            # asked for at a row, +share+ 65536ths of a wake into the frame (IR::Tunes.row_share). It is
            # asked for as the frame takes it up; of two before one wake, the later row's is kept.
            def emit_play_at_row(asm, at, memory)
              row = ->(plus = 0) { asm.abs_x(memory[ROWS], plus) }
              asm.label("rt_sfx_play_at_row")
              asm.lda(at.call(Music::EFFECT_CLOCK)) # the wake past the row, from the clock as it stands
              asm.clc
              asm.adc(asm.direct(Sound::R2))
              asm.lda(asm.direct(Sound::R2 + 2)) # LDA leaves the carry
              asm.adc(1)
              asm.sta(at.call(ASKED_WAKE))
              asm.ldx(0)
              asm.label("rt_sfx_play_at_row_find")
              asm.cpx(at.call(ROW_END))
              asm.bcs("rt_sfx_play_at_row_new")
              asm.lda(row.call)
              asm.cmp(at.call(ASKED_WAKE))
              asm.beq("rt_sfx_play_at_row_same")
              asm.txa
              asm.clc
              asm.adc(ROW_BYTES)
              asm.tax
              asm.bra("rt_sfx_play_at_row_find")
              asm.label("rt_sfx_play_at_row_same") # kept where its share is at least the one there
              asm.lda(asm.direct(Sound::R2 + 2))
              asm.cmp(row.call(10))
              asm.bcc("rt_sfx_play_at_row_done")
              asm.bne("rt_sfx_play_at_row_kept")
              asm.lda(asm.direct(Sound::R2))
              asm.cmp(row.call(8))
              asm.bcc("rt_sfx_play_at_row_done")
              asm.bra("rt_sfx_play_at_row_kept")
              asm.label("rt_sfx_play_at_row_new")
              asm.cpx(ROWS_MOST * ROW_BYTES)
              asm.bcs("rt_sfx_play_at_row_done")
              asm.txa
              asm.clc
              asm.adc(ROW_BYTES)
              asm.sta(at.call(ROW_END))
              asm.lda(at.call(ASKED_WAKE))
              asm.sta(row.call)
              asm.label("rt_sfx_play_at_row_kept")
              [[Sound::R0, 2], [Sound::R0 + 2, 4], [Sound::R1, 6], [Sound::R2, 8], [Sound::R2 + 2, 10]].each do |from, plus|
                asm.lda(asm.direct(from))
                asm.sta(row.call(plus))
              end
              asm.label("rt_sfx_play_at_row_done")
              asm.rtl
            end

            # rt_music_play_at_row(tune, share) and rt_music_play_from_list_at_row(which, list, share): the
            # tune named, from the next frame, at a row +share+ 65536ths of a wake into the frame: where
            # its start sets the effects' count, it sets it on the wake past the row.
            def emit_song_at_row(asm, at)
              asm.label("rt_music_play_at_row")
              asm.lda(asm.direct(Sound::R0))
              asm.sta(at.call(Music::NAMED))
              emit_song_row_kept(asm, at, Sound::R1)
              asm.rtl

              asm.label("rt_music_play_from_list_at_row")
              asm.jsr(asm.abs("rt_music_name_from_list"))
              asm.beq("rt_music_play_from_list_at_row_done")
              emit_song_row_kept(asm, at, Sound::R2)
              asm.label("rt_music_play_from_list_at_row_done")
              asm.rtl
            end

            # SONG_AT_ROW the tune NAMED, and its share the one in +register+.
            def emit_song_row_kept(asm, at, register)
              asm.lda(at.call(Music::NAMED))
              asm.sta(at.call(SONG_AT_ROW))
              asm.lda(asm.direct(register))
              asm.sta(at.call(SONG_ROW_SHARE))
              asm.lda(asm.direct(register + 2))
              asm.sta(at.call(SONG_ROW_SHARE, 2))
            end
          end
        end
      end
    end
  end
end
