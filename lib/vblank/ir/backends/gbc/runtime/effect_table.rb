# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        module Runtime
          # THE SOUND EFFECTS OF A GAME WITH MANY OF THEM, played by one set of routines from tables.
          #
          # Runtime::Effects writes each effect's routines out for it, which is quick to play and
          # takes the better part of a kilobyte of the part of the cartridge always in view for
          # each effect. A game that does not fit that way (GBC#roomier_view) keeps every effect's
          # notes and a row describing it in the banks, as the cartridges of the console's own games
          # keep theirs, and these routines read the row with its bank in view. In view stay these
          # routines, the same however many effects there are, and six bytes an effect.
          #
          # It plays what Runtime::Effects plays, step for step in the same order (Reference::Player).
          #
          # An effect's row (GBC::Music#emit_effect_row): whether it keeps its voices (one), how many
          # frames it lasts (two), how many parts it has (one), then for each part its voice, its
          # tone, how many notes (two) and where they are (two).
          #
          # What each effect keeps while it plays is Effects' STATE_BYTES and two for each part, in
          # STATE_STRIDE bytes of STATES, so where is a shift of its number.
          #
          # WHAT IS AWAKE. A frame has only so many cycles and most effects are quiet on most of
          # them, so a frame does not look at every effect to find that out. AWAKE lists the effects
          # asked for or sounding, highest rank first: how many, then for each its rank and its
          # number. An effect joins as it is asked for (rt_sfx_wake) and leaves when it has nothing
          # more to do (rt_sfx_sweep), so a frame's work follows what is sounding and not how many
          # effects the game has, and with nothing sounding a frame reads one byte.
          module EffectTable
            STATES = "rt sfx states"
            STATE_STRIDE = 16
            STATE_SHIFT = 4
            NOW = "rt sfx now"
            AWAKE = "rt sfx awake"
            AWAKE_ENTRY_BYTES = 2
            AWAKE_NUMBER = 1 # An entry's effect, after its rank

            # What NOW holds: the effect being played and what is read of it often.
            NUMBER = 0
            RANK = 1
            BANK = 2
            STATE_AT = 3 # Two bytes
            ROW_AT = 5 # Two bytes
            PART = 7
            CURSOR_AT = 8 # Two bytes
            # The effect asked for, the effect a walk has reached, and how far a walk over AWAKE has gone.
            ASKED_FOR = 10
            WALKED = 11
            AWAKE_AT = 12
            NOW_BYTES = 13

            # A row of "music_sfx_index", in view, by the effect's number.
            INDEX_BYTES = 6
            INDEX_RANK = 3
            INDEX_GROUP = 4
            INDEX_PRIORITY = 5

            ROW_TOTAL = 1
            ROW_PARTS = 3
            ROW_FIRST_PART = 4
            ROW_PART_BYTES = 6
            PART_COUNT = 2
            PART_NOTES = 4

            module_function

            def in_use?(memory) = memory.reserved?(STATES)

            def reserve(memory, effects)
              memory.reserve(Effects::HOLDERS, 4)
              memory.reserve(Effects::TUNE_RANK, 1)
              memory.reserve(STATES, STATE_STRIDE * effects.length)
              memory.reserve(NOW, NOW_BYTES)
              memory.reserve(AWAKE, 1 + (AWAKE_ENTRY_BYTES * effects.length))
            end

            # +_by_rank+ is what Runtime::Effects takes in the same place: here AWAKE keeps the order.
            def emit(asm, memory, effects, _by_rank, slides: false, pans: false, fades: false, bytes: GBC::Music::NOTE_BYTES)
              keeps = effects.any?(&:keeps_voices)
              Effects.emit_claim(asm, memory, fades)
              Effects.emit_claim_keeping(asm, memory) if keeps
              Effects.emit_tune_rank(asm, memory)
              Effects.emit_note(asm, memory, slides, pans)
              emit_places(asm, memory)
              emit_sides(asm, memory)
              emit_sweep(asm, memory)
              emit_frame(asm, memory)
              emit_part(asm, memory, keeps, bytes)
              emit_finish(asm, memory, effects)
              emit_ask(asm, memory)
            end

            # The routines that return where things are, which everything below leans on.
            def emit_places(asm, memory)
              now = memory[NOW]
              asm.label("rt_sfx_index") # A = an effect: HL at its row of the index
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.add_hl(:hl)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:de, "music_sfx_index")
              asm.add_hl(:de)
              asm.ret

              asm.label("rt_sfx_state") # A = an effect: HL at what it keeps
              asm.load(:l, :a)
              asm.load(:h, 0)
              STATE_SHIFT.times { asm.add_hl(:hl) }
              asm.load(:de, memory[STATES])
              asm.add_hl(:de)
              asm.ret

              # rt_sfx_asleep(A = an effect): Z when it is not asked for, stopping or running, and
              # HL left at its ASKED. Keeps BC.
              asm.label("rt_sfx_asleep")
              asm.call("rt_sfx_state")
              asm.load(:a, [:hli]) # ASKED
              asm.or_a([:hl]) # STOPPING
              asm.inc(:hl)
              asm.or_a([:hl]) # RUNNING
              asm.dec(:hl)
              asm.dec(:hl) # which touches no flag
              asm.ret

              asm.label("rt_sfx_state_now") # HL at what the effect being played keeps
              asm.load(:a, [now + STATE_AT])
              asm.load(:l, :a)
              asm.load(:a, [now + STATE_AT + 1])
              asm.load(:h, :a)
              asm.ret

              asm.label("rt_sfx_row_now") # HL at the row of the effect being played
              asm.load(:a, [now + ROW_AT])
              asm.load(:l, :a)
              asm.load(:a, [now + ROW_AT + 1])
              asm.load(:h, :a)
              asm.ret

              asm.label("rt_sfx_part_row") # HL at the row's entry for the part being played
              asm.load(:a, [now + PART])
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.add_hl(:hl)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.add_hl(:hl)
              asm.add_hl(:de)
              asm.load(:a, [now + ROW_AT])
              asm.load(:e, :a)
              asm.load(:a, [now + ROW_AT + 1])
              asm.load(:d, :a)
              asm.add_hl(:de)
              asm.load(:de, ROW_FIRST_PART)
              asm.add_hl(:de)
              asm.ret

              # rt_sfx_load(A = an effect): it is the effect being played, and its bank in view.
              asm.label("rt_sfx_load")
              asm.load([now + NUMBER], :a)
              asm.push(:af)
              asm.call("rt_sfx_state")
              asm.load(:a, :l)
              asm.load([now + STATE_AT], :a)
              asm.load(:a, :h)
              asm.load([now + STATE_AT + 1], :a)
              asm.pop(:af)
              asm.call("rt_sfx_index")
              asm.load(:a, [:hli])
              asm.load([now + ROW_AT], :a)
              asm.load(:a, [:hli])
              asm.load([now + ROW_AT + 1], :a)
              asm.load(:a, [:hli])
              asm.load([now + BANK], :a)
              asm.load(:b, :a)
              asm.load(:a, [:hl])
              asm.load([now + RANK], :a)
              asm.load(:a, :b)
              asm.select_rom_bank_unnoted
              asm.ret

              asm.label("rt_sfx_bank_back") # the game's bank in view again
              asm.load(:a, [memory[Music::BANK_NOTED]])
              asm.select_rom_bank_unnoted
              asm.ret
            end

            # rt_sfx_above and rt_sfx_below, as Runtime::Effects says them, a walk over AWAKE. The
            # walk leaves the list as it is, and rt_sfx_below goes on into rt_sfx_sweep, which clears
            # it of whatever the two walks finished.
            def emit_sides(asm, memory)
              { "above" => :nc, "below" => :c }.each do |side, skip|
                asm.label("rt_sfx_#{side}")
                asm.load(:hl, memory[AWAKE])
                asm.load(:a, [:hli])
                asm.and_a(:a)
                asm.ret(:z)
                asm.load(:b, :a)
                asm.label("rt_sfx_#{side}_each")
                asm.load(:a, [:hli])
                asm.load(:c, :a)
                asm.load(:a, [:hli])
                asm.load(:e, :a)
                asm.load(:a, [memory[Effects::TUNE_RANK]])
                asm.cp_a(:c)
                asm.jump_relative(skip, "rt_sfx_#{side}_past")
                asm.push(:hl)
                asm.push(:bc)
                asm.load(:a, :e)
                asm.call("rt_sfx_frame")
                asm.pop(:bc)
                asm.pop(:hl)
                asm.label("rt_sfx_#{side}_past")
                asm.dec(:b)
                asm.jump_relative(:nz, "rt_sfx_#{side}_each")
                asm.ret if side == "above"
              end
            end

            # rt_sfx_sweep: AWAKE closed up over every effect with nothing left to do, which keeps
            # the rest in their order. It is only reached with something in the list.
            def emit_sweep(asm, memory)
              asm.label("rt_sfx_sweep")
              asm.load(:hl, memory[AWAKE])
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.load(:c, 0) # how many stay
              asm.load(:d, :h) # DE = where the next to stay goes
              asm.load(:e, :l)
              asm.label("rt_sfx_sweep_each")
              asm.push(:de)
              asm.push(:hl)
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.call("rt_sfx_asleep")
              asm.pop(:hl)
              asm.pop(:de)
              asm.jump_relative(:z, "rt_sfx_sweep_gone")
              asm.inc(:c)
              AWAKE_ENTRY_BYTES.times do
                asm.load(:a, [:hli])
                asm.load([:de], :a)
                asm.inc(:de)
              end
              asm.jump_relative("rt_sfx_sweep_past")
              asm.label("rt_sfx_sweep_gone")
              AWAKE_ENTRY_BYTES.times { asm.inc(:hl) }
              asm.label("rt_sfx_sweep_past")
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_sfx_sweep_each")
              asm.load(:a, :c)
              asm.load([memory[AWAKE]], :a)
              asm.ret
            end

            # rt_sfx_frame(A = an effect in AWAKE): one frame of it, Runtime::Effects#emit_frame's.
            # A run of the cartridge reads the effect starting at rt_sfx_started, in A.
            def emit_frame(asm, memory)
              now = memory[NOW]
              asm.label("rt_sfx_frame")
              asm.call("rt_sfx_load")
              asm.call("rt_sfx_frame_in_view")
              asm.jump("rt_sfx_bank_back")

              asm.label("rt_sfx_frame_in_view")
              asm.call("rt_sfx_state_now")
              asm.inc(:hl) # STOPPING
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_frame_not_stopped")
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.call("rt_sfx_finish")
              asm.label("rt_sfx_frame_not_stopped")
              asm.call("rt_sfx_state_now")
              asm.load(:a, [:hl]) # ASKED
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_frame_sounding")
              asm.xor_a(:a)
              asm.load([:hli], :a)
              asm.inc(:hl)
              asm.load(:a, 1)
              asm.load([:hli], :a) # RUNNING
              asm.xor_a(:a)
              (STATE_STRIDE - Effects::FRAME).times { asm.load([:hli], :a) }
              asm.load(:a, [now + NUMBER])
              asm.label("rt_sfx_started")
              asm.jump("rt_sfx_frame_play")
              asm.label("rt_sfx_frame_sounding")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.load(:a, [:hli]) # RUNNING
              asm.and_a(:a)
              asm.ret(:z)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:b, [:hl]) # BC = its frame
              asm.call("rt_sfx_row_now")
              asm.inc(:hl) # ROW_TOTAL
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl])
              asm.load(:a, :b)
              asm.cp_a(:d)
              asm.jump_relative(:c, "rt_sfx_frame_play")
              asm.jump(:nz, "rt_sfx_finish")
              asm.load(:a, :c)
              asm.cp_a(:e)
              asm.jump(:nc, "rt_sfx_finish")
              asm.label("rt_sfx_frame_play")
              asm.xor_a(:a)
              asm.load([now + PART], :a)
              asm.label("rt_sfx_frame_part")
              asm.call("rt_sfx_row_now")
              asm.load(:de, ROW_PARTS)
              asm.add_hl(:de)
              asm.load(:b, [:hl])
              asm.load(:a, [now + PART])
              asm.cp_a(:b)
              asm.jump_relative(:nc, "rt_sfx_frame_parts_done")
              asm.call("rt_sfx_part")
              asm.load(:hl, now + PART)
              asm.inc([:hl])
              asm.jump_relative("rt_sfx_frame_part")
              asm.label("rt_sfx_frame_parts_done")
              asm.call("rt_sfx_state_now")
              asm.load(:de, Effects::FRAME)
              asm.add_hl(:de)
              asm.inc([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.inc([:hl])
              asm.ret
            end

            # rt_sfx_part: the part being played: its next note, if this is its frame, the part moved
            # on past it and the note played if the voice is the effect's to take
            # (Runtime::Effects#emit_effect_part). A holds the bank as the note goes to rt_sfx_note,
            # which is how a run of the cartridge tells two banks' notes at one address apart.
            def emit_part(asm, memory, keeps, bytes)
              now = memory[NOW]
              asm.label("rt_sfx_part")
              asm.call("rt_sfx_state_now")
              asm.load(:a, [now + PART])
              asm.add_a(:a)
              asm.add_a(Effects::CURSORS)
              asm.load(:e, :a)
              asm.load(:d, 0)
              asm.add_hl(:de)
              asm.load(:a, :l)
              asm.load([now + CURSOR_AT], :a)
              asm.load(:a, :h)
              asm.load([now + CURSOR_AT + 1], :a)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl]) # DE = which note is next
              asm.push(:de)
              asm.call("rt_sfx_part_row")
              asm.pop(:de)
              PART_COUNT.times { asm.inc(:hl) }
              asm.load(:a, [:hli])
              asm.cp_a(:e)
              asm.jump_relative(:nz, "rt_sfx_part_more")
              asm.load(:a, [:hl])
              asm.cp_a(:d)
              asm.ret(:z) # no more notes
              asm.label("rt_sfx_part_more")
              asm.push(:de) # rt_sfx_part_row takes DE, and the next note's number is in it
              asm.call("rt_sfx_part_row")
              asm.load(:de, PART_NOTES)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:c, :a)
              asm.load(:b, [:hl]) # BC = where its notes are
              asm.pop(:hl)
              asm.load(:d, :h)
              asm.load(:e, :l)
              asm.push(:bc)
              Music.emit_times_note_bytes(asm, bytes)
              asm.pop(:de)
              asm.add_hl(:de) # HL = the note
              asm.push(:hl)
              asm.call("rt_sfx_state_now")
              asm.load(:de, Effects::FRAME)
              asm.add_hl(:de)
              asm.load(:a, [:hli])
              asm.load(:e, :a)
              asm.load(:d, [:hl]) # DE = the effect's frame
              asm.pop(:hl)
              asm.load(:a, :e)
              asm.cp_a([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.load(:a, :d)
              asm.cp_a([:hl])
              asm.ret(:nz)
              asm.inc(:hl)
              asm.push(:hl) # the note, past its frame
              asm.load(:a, [now + CURSOR_AT])
              asm.load(:l, :a)
              asm.load(:a, [now + CURSOR_AT + 1])
              asm.load(:h, :a)
              asm.inc([:hl])
              asm.jump_relative(:nz, "rt_sfx_part_counted")
              asm.inc(:hl)
              asm.inc([:hl])
              asm.label("rt_sfx_part_counted")
              asm.call("rt_sfx_part_row")
              part = memory[Music::PART]
              asm.load(:a, [:hli])
              asm.load([part], :a)
              asm.load(:a, [:hl])
              asm.load([part + 1], :a)
              if keeps
                asm.call("rt_sfx_row_now")
                asm.load(:a, [:hl])
                asm.load(:b, :a)
              end
              asm.pop(:hl)
              asm.load(:a, [now + RANK])
              asm.load(:c, :a)
              if keeps
                asm.load(:a, :b)
                asm.and_a(:a)
                asm.jump_relative(:z, "rt_sfx_part_claims")
                asm.call("rt_claim_keeping")
                asm.jump_relative("rt_sfx_part_claimed")
                asm.label("rt_sfx_part_claims")
              end
              asm.call("rt_claim")
              asm.label("rt_sfx_part_claimed") if keeps
              asm.ret(:c)
              asm.load(:a, [now + BANK])
              asm.jump("rt_sfx_note")
            end

            # rt_sfx_finish: the effect being played is over, and every voice it still holds goes
            # quiet and is nobody's (Runtime::Effects#emit_finish). A voice two parts share is
            # let go once, since the second time nobody holds it at this rank. A run of the cartridge
            # reads each voice let go at rt_sfx_free, the effect in B and the voice in C.
            def emit_finish(asm, memory, effects)
              now = memory[NOW]
              holders = memory[Effects::HOLDERS]
              asm.label("rt_sfx_finish")
              asm.call("rt_sfx_state_now")
              asm.inc(:hl)
              asm.inc(:hl)
              asm.xor_a(:a)
              asm.load([:hl], :a) # RUNNING
              asm.load([now + PART], :a)
              asm.label("rt_sfx_finish_part")
              asm.call("rt_sfx_row_now")
              asm.load(:de, ROW_PARTS)
              asm.add_hl(:de)
              asm.load(:b, [:hl])
              asm.load(:a, [now + PART])
              asm.cp_a(:b)
              asm.ret(:nc)
              asm.call("rt_sfx_part_row")
              asm.load(:c, [:hl]) # the voice
              asm.load(:a, :c)
              asm.dec(:a)
              asm.add_a(holders & 0xFF)
              asm.load(:l, :a)
              asm.load(:a, holders >> 8)
              asm.adc_a(0)
              asm.load(:h, :a)
              asm.load(:a, [now + RANK])
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_sfx_finish_kept")
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.load(:a, [now + NUMBER])
              asm.load(:b, :a)
              asm.label("rt_sfx_free")
              asm.call("rt_sfx_silence")
              asm.label("rt_sfx_finish_kept")
              asm.load(:hl, now + PART)
              asm.inc([:hl])
              asm.jump("rt_sfx_finish_part")

              asm.label("rt_sfx_silence") # C = a voice
              effects.flat_map { |effect| effect.parts.map(&:voice) }.uniq.sort.each do |voice|
                asm.load(:a, :c)
                asm.cp_a(voice)
                asm.jump(:nz, "rt_sfx_silence_not_#{voice}")
                Music.emit_silence(asm, memory, voice)
                asm.ret
                asm.label("rt_sfx_silence_not_#{voice}")
              end
              asm.ret
            end

            # rt_sfx_ask(A = an effect) and rt_sfx_now, Runtime::Effects#emit_ask's, in the
            # frame's interrupt held off. rt_sfx_decide sees to the effect's group and, unless it
            # is not to be played, answers with no carry and the effect marked asked for.
            def emit_ask(asm, memory)
              asm.label("rt_sfx_ask")
              asm.di
              asm.call("rt_sfx_decide")
              asm.reti

              asm.label("rt_sfx_now")
              asm.di
              asm.call("rt_sfx_decide")
              asm.jump_relative(:nc, "rt_sfx_now_starts")
              asm.reti
              asm.label("rt_sfx_now_starts")
              Clips.emit_timer_let_in_around(asm, memory) { asm.call("rt_sfx_start_here") }
              asm.reti

              emit_decide(asm, memory)
              emit_wake(asm, memory)
              emit_start_here(asm, memory)
            end

            # The one of its group sounding is asked for or running, so it is awake: the walk is over
            # AWAKE, not over every effect, and costs what is sounding, however many effects the game
            # declares. No two of a group are asked for or running and not stopping at once, so the
            # order of the walk does not change which it finds.
            def emit_decide(asm, memory)
              now = memory[NOW]
              asm.label("rt_sfx_decide")
              asm.load([now + ASKED_FOR], :a)
              asm.call("rt_sfx_index")
              asm.load(:de, INDEX_GROUP)
              asm.add_hl(:de)
              asm.load(:b, [:hl]) # B = its group
              asm.inc(:hl)
              asm.load(:c, [:hl]) # C = its priority
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_decide_asked")
              asm.xor_a(:a)
              asm.load([now + AWAKE_AT], :a)
              asm.label("rt_sfx_decide_each")
              asm.load(:a, [now + AWAKE_AT])
              asm.load(:hl, memory[AWAKE])
              asm.cp_a([:hl])
              asm.jump_relative(:nc, "rt_sfx_decide_asked")
              # HL = that entry's effect: past AWAKE's count, the place's entries, and the entry's rank.
              # Must change with AWAKE_ENTRY_BYTES: the place is doubled with one add.
              asm.load(:l, :a)
              asm.load(:h, 0)
              asm.add_hl(:hl)
              asm.load(:de, memory[AWAKE] + 1 + AWAKE_NUMBER)
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.load([now + WALKED], :a)
              asm.call("rt_sfx_index")
              asm.load(:de, INDEX_GROUP)
              asm.add_hl(:de)
              asm.load(:a, [:hl])
              asm.cp_a(:b)
              asm.jump_relative(:nz, "rt_sfx_decide_next")
              asm.load(:a, [now + WALKED])
              asm.call("rt_sfx_state")
              asm.load(:a, [:hli]) # ASKED
              asm.and_a(:a)
              asm.jump_relative(:nz, "rt_sfx_decide_current")
              asm.load(:a, [:hli]) # STOPPING
              asm.load(:e, :a)
              asm.load(:a, [:hl]) # RUNNING
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_decide_next")
              asm.load(:a, :e)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_decide_current")
              asm.label("rt_sfx_decide_next")
              asm.load(:hl, now + AWAKE_AT)
              asm.inc([:hl])
              asm.jump_relative("rt_sfx_decide_each")
              # The one of its group sounding: of higher priority, it keeps on and carry marks it.
              asm.label("rt_sfx_decide_current")
              asm.load(:a, [now + WALKED])
              asm.call("rt_sfx_index")
              asm.load(:de, INDEX_PRIORITY)
              asm.add_hl(:de)
              asm.load(:a, :c)
              asm.cp_a([:hl])
              asm.ret(:c)
              asm.load(:a, [now + WALKED])
              asm.call("rt_sfx_state")
              asm.xor_a(:a)
              asm.load([:hli], :a) # ASKED
              asm.load(:a, 1)
              asm.load([:hl], :a) # STOPPING
              asm.label("rt_sfx_decide_asked")
              asm.load(:a, [now + ASKED_FOR])
              asm.call("rt_sfx_asleep")
              asm.load(:c, :a)
              asm.load(:a, 1)
              asm.load([:hl], :a) # ASKED
              asm.load(:a, :c)
              asm.and_a(:a) # no carry
              asm.ret(:nz) # it was awake, so it is in AWAKE
              # ...and on into rt_sfx_wake, which keeps carry clear.
            end

            # rt_sfx_wake: the effect asked for joins AWAKE in its place by rank. The new entry walks
            # down the list, changing places with each entry of lower rank it meets, and the entry
            # it is carrying at the end takes the free place. No two effects share a rank.
            def emit_wake(asm, memory)
              now = memory[NOW]
              asm.load(:a, [now + ASKED_FOR])
              asm.call("rt_sfx_index")
              asm.load(:de, INDEX_RANK)
              asm.add_hl(:de)
              asm.load(:e, [:hl]) # D, E = the entry being carried: its number and rank
              asm.load(:a, [now + ASKED_FOR])
              asm.load(:d, :a)
              asm.load(:hl, memory[AWAKE])
              asm.load(:b, [:hl])
              asm.inc([:hl])
              asm.inc(:hl)
              asm.label("rt_sfx_wake_each")
              asm.load(:a, :b)
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_wake_place")
              asm.load(:a, [:hl])
              asm.cp_a(:e)
              asm.jump_relative(:nc, "rt_sfx_wake_past")
              asm.load([:hl], :e)
              asm.load(:e, :a)
              asm.inc(:hl)
              asm.load(:a, [:hl])
              asm.load([:hl], :d)
              asm.load(:d, :a)
              asm.dec(:hl)
              asm.label("rt_sfx_wake_past")
              AWAKE_ENTRY_BYTES.times { asm.inc(:hl) }
              asm.dec(:b)
              asm.jump_relative("rt_sfx_wake_each")
              asm.label("rt_sfx_wake_place")
              asm.load([:hl], :e)
              asm.inc(:hl)
              asm.load([:hl], :d)
              asm.ret # A is 0, carry clear
            end

            # Runtime::Effects#emit_start_here: every effect awake in rank order, the one asked for
            # taking its first frame and every other waiting to be stopped stopped.
            def emit_start_here(asm, memory)
              now = memory[NOW]
              asm.label("rt_sfx_start_here")
              asm.load(:hl, memory[AWAKE])
              asm.load(:a, [:hli])
              asm.load(:b, :a)
              asm.label("rt_sfx_start_each")
              asm.inc(:hl)
              asm.load(:a, [:hli])
              asm.push(:hl)
              asm.push(:bc)
              asm.load(:hl, now + ASKED_FOR)
              asm.cp_a([:hl])
              asm.jump_relative(:nz, "rt_sfx_start_other")
              asm.call("rt_sfx_frame")
              asm.jump_relative("rt_sfx_start_past")
              asm.label("rt_sfx_start_other")
              asm.load([now + WALKED], :a)
              asm.call("rt_sfx_state")
              asm.inc(:hl) # STOPPING
              asm.load(:a, [:hl])
              asm.and_a(:a)
              asm.jump_relative(:z, "rt_sfx_start_past")
              asm.xor_a(:a)
              asm.load([:hl], :a)
              asm.load(:a, [now + WALKED])
              asm.call("rt_sfx_load")
              asm.call("rt_sfx_finish")
              asm.call("rt_sfx_bank_back")
              asm.label("rt_sfx_start_past")
              asm.pop(:bc)
              asm.pop(:hl)
              asm.dec(:b)
              asm.jump_relative(:nz, "rt_sfx_start_each")
              asm.jump("rt_sfx_sweep")
            end
          end
        end
      end
    end
  end
end
