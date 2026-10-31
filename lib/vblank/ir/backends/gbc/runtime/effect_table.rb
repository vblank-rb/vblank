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
          # each effect. A game that does not fit that way (GBC#build_cartridge) keeps every effect's
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
          module EffectTable
            STATES = "rt sfx states"
            STATE_STRIDE = 16
            STATE_SHIFT = 4
            NOW = "rt sfx now"

            # What NOW holds: the effect being played and what is read of it often.
            NUMBER = 0
            RANK = 1
            BANK = 2
            STATE_AT = 3 # two bytes
            ROW_AT = 5 # two bytes
            PART = 7
            CURSOR_AT = 8 # two bytes
            # The effect asked for, and how far a walk over the effects has gone.
            ASKED_FOR = 10
            WALKED = 11
            NOW_BYTES = 12

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
            end

            def emit(asm, memory, effects, by_rank, slides: false, pans: false, fades: false, bytes: GBC::Music::NOTE_BYTES)
              keeps = effects.any?(&:keeps_voices)
              Effects.emit_claim(asm, memory, fades)
              Effects.emit_claim_keeping(asm, memory) if keeps
              Effects.emit_tune_rank(asm, memory)
              Effects.emit_note(asm, memory, slides, pans)
              emit_places(asm, memory)
              emit_sides(asm, memory, by_rank)
              emit_frame(asm, memory)
              emit_part(asm, memory, keeps, bytes)
              emit_finish(asm, memory, effects)
              emit_ask(asm, memory, effects, by_rank)
            end

            # The routines that say where things are, which everything below leans on.
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

            # rt_sfx_above and rt_sfx_below, as Runtime::Effects says them, a walk over the effects
            # highest rank first (music_sfx_by_rank, two bytes each: the effect and its rank).
            def emit_sides(asm, memory, by_rank)
              { "above" => :nc, "below" => :c }.each do |side, skip|
                asm.label("rt_sfx_#{side}")
                asm.load(:hl, "music_sfx_by_rank")
                asm.load(:b, by_rank.length)
                asm.label("rt_sfx_#{side}_each")
                asm.load(:a, [:hli])
                asm.load(:e, :a)
                asm.load(:a, [:hli])
                asm.load(:c, :a)
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
                asm.ret
              end
            end

            # rt_sfx_frame(A = an effect): one frame of it, Runtime::Effects#emit_frame's, and its
            # bank put in view only for one with something to do. Most effects are asleep on most
            # frames. A run of the cartridge reads the effect starting at rt_sfx_started, in A.
            def emit_frame(asm, memory)
              now = memory[NOW]
              asm.label("rt_sfx_frame")
              asm.push(:af)
              asm.call("rt_sfx_state")
              asm.load(:a, [:hli]) # ASKED
              asm.or_a([:hl]) # STOPPING
              asm.inc(:hl)
              asm.or_a([:hl]) # RUNNING
              asm.jump_relative(:nz, "rt_sfx_frame_awake")
              asm.pop(:af)
              asm.ret
              asm.label("rt_sfx_frame_awake")
              asm.pop(:af)
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
            def emit_ask(asm, memory, effects, by_rank)
              now = memory[NOW]
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

              emit_decide(asm, now, effects)
              emit_start_here(asm, now, by_rank)
            end

            def emit_decide(asm, now, effects)
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
              asm.load([now + WALKED], :a)
              asm.label("rt_sfx_decide_each")
              asm.load(:a, [now + WALKED])
              asm.cp_a(effects.length)
              asm.jump_relative(:nc, "rt_sfx_decide_asked")
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
              asm.load(:hl, now + WALKED)
              asm.inc([:hl])
              asm.jump_relative("rt_sfx_decide_each")
              # The one of its group sounding: of higher priority, it keeps on and carry says so.
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
              asm.call("rt_sfx_state")
              asm.load(:a, 1)
              asm.load([:hl], :a) # ASKED
              asm.and_a(:a) # no carry
              asm.ret
            end

            # Runtime::Effects#emit_start_here: every effect in rank order, the one asked for taking
            # its first frame and every other waiting to be stopped stopped.
            def emit_start_here(asm, now, by_rank)
              asm.label("rt_sfx_start_here")
              asm.load(:hl, "music_sfx_by_rank")
              asm.load(:b, by_rank.length)
              asm.label("rt_sfx_start_each")
              asm.load(:a, [:hli])
              asm.inc(:hl)
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
              asm.ret
            end
          end
        end
      end
    end
  end
end
