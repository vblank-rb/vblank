# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE SOUND EFFECTS PLAYER, beside the tune's (Music), the same steps as Reference::Player's, in its
          # order.
          #
          # The game asks for an effect (rt_sfx_play); at the next frame it starts from its first note, plays
          # each note once as its frame comes, and at its end lets go of the voices it still holds, quieting
          # them. The tune and the effects share the console's four voices, and WHO SOUNDS ON ONE is settled by
          # rank (SNES::Music, "who sounds on a voice"): a note takes a voice whose holder's rank is no higher
          # than its own, and holds it while it makes a sound (rt_sfx_claim). Each frame plays the effects that
          # outrank the tune before the tune's parts and the rest after, so whoever writes a voice first on a
          # frame is whoever keeps it.
          #
          # AN EFFECT IN A GROUP plays one at a time with the rest of its group: asked for while another of its
          # group is sounding or already asked for, it is not played if its priority is lower, and otherwise
          # stops that one on the next frame and starts in its place (Reference::Player#request_effect).
          module Effects
            # Which voice each holder holds, by channel (1..4, two bytes each from channel 1): the holder's
            # rank's place; and the channels in the order each was first held, as the interpreter's Hash keeps
            # them, which is the order an effect's end lets them go in.
            HOLDERS = "rt sfx holders"
            HOLDER_ORDER = "rt sfx holder order"
            HOLDER_END = "rt sfx holder end"
            HOLDER_SEEN = "rt sfx holder seen"
            # A claim on a voice: its channel, the rank asking, and whether the note sounds.
            CLAIM_CHANNEL = "rt sfx claim channel"
            CLAIM_RANK = "rt sfx claim rank"
            CLAIM_SOUNDS = "rt sfx claim sounds"
            # The tune's rank's place, plus one, as a frame starts; nought for no tune.
            TUNE_RANK = "rt sfx tune rank"
            # The effect being played: its number, where its record and its state are (addresses), the part
            # being played and how many, that part's entry and its note (addresses).
            EFFECT = "rt sfx effect"
            RECORD = "rt sfx record"
            STATE = "rt sfx state"
            PART = "rt sfx part"
            PARTS = "rt sfx parts"
            ENTRY = "rt sfx entry"
            NOTE = "rt sfx note"
            # Where in the effects' rank order a frame is; and where in HOLDER_ORDER an effect's end is, apart,
            # since an effect is ended in the middle of a walk through the rank order.
            WALK = "rt sfx walk"
            RELEASE_WALK = "rt sfx release walk"
            # An effect's end: its rank's place, and the voice it is letting go.
            RELEASE_RANK = "rt sfx release rank"
            RELEASE_CHANNEL = "rt sfx release channel"
            # An effect asked for: its number, group and priority; and another of its group.
            ASKED_EFFECT = "rt sfx asked effect"
            ASKED_GROUP = "rt sfx asked group"
            ASKED_PRIORITY = "rt sfx asked priority"
            OTHER = "rt sfx other"
            # Each effect's state, STATE_BYTES apart: asked for since the last frame; asked for, as a frame
            # plays it; to be cut off; sounding; how far into it; each part's next note.
            STATES = "rt sfx states"
            ASKED = 0
            ASKED_NOW = 2
            STOPPING = 4
            RUNNING = 6
            FRAME = 8
            CURSORS = 10
            STATE_BYTES = 64 # past CURSORS and a word for each of the most parts an effect has

            CHANNELS = (1..4).freeze

            module_function

            def reserve(memory, effects)
              [HOLDER_END, CLAIM_CHANNEL, CLAIM_RANK, CLAIM_SOUNDS, TUNE_RANK, EFFECT, PART, PARTS, WALK, RELEASE_WALK,
               RELEASE_RANK, RELEASE_CHANNEL, ASKED_EFFECT, ASKED_GROUP, ASKED_PRIORITY, OTHER].each { |name| memory.reserve(name, 2) }
              [RECORD, STATE, ENTRY, NOTE].each { |name| memory.reserve(name, 4) }
              [HOLDERS, HOLDER_ORDER, HOLDER_SEEN].each { |name| memory.reserve(name, CHANNELS.size * 2) }
              memory.reserve(STATES, effects * STATE_BYTES)
            end

            # +count+ is how many effects the game has; +level_at+ where its music volume is, if it sets one,
            # since an effect taking a voice takes the tune's note there out of those a new level reaches.
            # +recorded+ when a song or effect has a part that plays a recording.
            def emit(asm, memory, count, level_at, recorded: false)
              at = ->(name, plus = 0) { asm.disp(5, memory.displacement(name) + plus) }
              emit_game_side(asm, at, count)
              emit_passes(asm, at, count)
              emit_frame(asm, at, memory, level_at, recorded)
              emit_finish(asm, at, memory, recorded)
              emit_recorded_parts(asm, at) if recorded
              emit_claim_routine(asm, at)
              emit_select(asm, at)
              emit_effect_holds(asm, at)
            end

            # A call of rt_sfx_claim, inline, by the rank's place in D0, for the part whose entry and note are
            # at +entry+ and +note+. The zero flag is clear when the note takes the voice, and set when a holder
            # of a higher rank keeps it.
            def emit_claim_call(asm, at, entry: Music::ENTRY, note: Music::NOTE)
              m = Genesis::Music
              asm.move(:w, asm.d(0), at.call(CLAIM_RANK))
              asm.movea(:l, at.call(entry), asm.a(0))
              asm.move(:w, asm.disp(0, m::CHANNEL), at.call(CLAIM_CHANNEL))
              asm.movea(:l, at.call(note), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_SOUNDS), at.call(CLAIM_SOUNDS))
              asm.jsr(asm.abs_l("rt_sfx_claim"))
              asm.tst(:w, asm.d(0))
            end

            # rt_sfx_effect_holds: D0, and the zero flag clear, when a sound effect holds the voice D4 says (two
            # bytes a voice, from channel 1), rather than the tune or nobody. D4 is kept.
            def emit_effect_holds(asm, at)
              asm.label("rt_sfx_effect_holds")
              asm.lea(at.call(HOLDERS), asm.a(0))
              asm.move(:w, asm.idx(0, 0, 4, :w), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.add(:w, asm.disp(0, Genesis::Music::RANK_KINDS_AT), asm.d(0))
              Music.emit_table_place(asm, 2)
              asm.move(:w, asm.ind(2), asm.d(0))
              asm.rts
            end

            # As the tune stops, inline: D0, the voices its parts play on, less those a sound effect holds; and
            # every voice the tune holds, or nobody does, free (Reference::Player#silence_song).
            def emit_release_tune_voices(asm, at)
              asm.move(:w, asm.d(0), asm.d(5))
              CHANNELS.each do |channel|
                kept = "rt_music_quiet_kept_#{channel}"
                done = "rt_music_quiet_done_#{channel}"
                asm.move(:w, asm.imm((channel - 1) * 2), asm.d(4))
                asm.jsr(asm.abs_l("rt_sfx_effect_holds"))
                asm.branch(:ne, kept)
                asm.clr(:w, at.call(HOLDERS, (channel - 1) * 2))
                asm.bra(done)
                asm.label(kept) # an effect's: not let go
                asm.and(:w, asm.imm(~(1 << ChipWrites::CHANNEL_VOICES.fetch(channel)) & 0xFFFF), asm.d(5))
                asm.label(done)
              end
              asm.move(:w, asm.d(5), asm.d(0))
            end

            # rt_sfx_play(which, list): the effect at place +which+ of effect list +list+ starts at the next
            # frame (Reference::Player#request_effect); rt_sfx_play_now, here (Reference::Player#start_effect_here).
            def emit_game_side(asm, at, count)
              m = Genesis::Music
              state = ->(field) { asm.disp(1, field) }
              asm.label("rt_sfx_play")
              asm.jmp(asm.abs_l("rt_sfx_request"))

              asm.label("rt_sfx_play_now")
              asm.jsr(asm.abs_l("rt_sfx_request"))
              asm.tst(:w, asm.d(0))
              asm.branch(:ne, "rt_sfx_play_now_asked")
              asm.rts
              asm.label("rt_sfx_play_now_asked")
              asm.move(:w, at.call(ASKED_EFFECT), asm.d(0))
              asm.jsr(asm.abs_l("rt_sfx_select"))
              asm.clr(:w, state.call(ASKED))
              # Every effect, in rank order: this one plays its first frame; one of a group waiting to be cut
              # off is cut off here.
              asm.clr(:w, at.call(WALK))
              asm.label("rt_sfx_play_now_next")
              asm.jsr(asm.abs_l("rt_sfx_select_ranked"))
              asm.cmp(:w, at.call(ASKED_EFFECT), asm.d(0))
              asm.branch(:ne, "rt_sfx_play_now_other")
              asm.move(:w, asm.imm(1), state.call(ASKED_NOW))
              asm.jsr(asm.abs_l("rt_sfx_frame"))
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.clr(:w, state.call(ASKED_NOW))
              asm.bra("rt_sfx_play_now_walk")
              asm.label("rt_sfx_play_now_other")
              asm.tst(:w, state.call(STOPPING))
              asm.branch(:eq, "rt_sfx_play_now_walk")
              asm.clr(:w, state.call(STOPPING))
              asm.jsr(asm.abs_l("rt_sfx_finish"))
              asm.label("rt_sfx_play_now_walk")
              asm.addq(:w, 1, at.call(WALK))
              asm.cmp(:w, asm.imm(count), at.call(WALK))
              asm.branch(:cs, "rt_sfx_play_now_next")
              asm.rts

              # rt_sfx_request: the effect at place D0 (32 bits) of list D1 asked for, D0 = 1 and ASKED_EFFECT its
              # number; or D0 = nought, for a place outside the list or an effect its group's sounding one outranks.
              asm.label("rt_sfx_request")
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, m::EFFECT_LISTS_AT), asm.d(2))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.add(:l, asm.d(1), asm.d(2))
              asm.move(:w, asm.idx(0, 0, 2), asm.d(2))
              asm.lea(asm.idx(0, 0, 2), asm.a(1))
              asm.moveq(0, asm.d(3))
              asm.move(:w, asm.ind(1), asm.d(3)) # how many effects the list holds
              asm.cmp(:l, asm.d(3), asm.d(0))
              asm.branch(:cc, "rt_sfx_request_none")
              asm.add(:l, asm.d(0), asm.d(0))
              asm.move(:w, asm.idx(1, 2, 0), at.call(ASKED_EFFECT))
              asm.move(:w, at.call(ASKED_EFFECT), asm.d(0))
              asm.jsr(asm.abs_l("rt_sfx_select"))
              asm.move(:w, asm.disp(0, m::EFFECT_GROUP), at.call(ASKED_GROUP))
              asm.branch(:eq, "rt_sfx_request_ask")
              asm.move(:w, asm.disp(0, m::EFFECT_PRIORITY), at.call(ASKED_PRIORITY))
              # The first of its group, in the order declared, asked for or sounding and not stopping.
              asm.clr(:w, at.call(OTHER))
              asm.label("rt_sfx_request_find")
              asm.move(:w, at.call(OTHER), asm.d(0))
              asm.cmp(:w, asm.imm(count), asm.d(0))
              asm.branch(:cc, "rt_sfx_request_ask")
              asm.jsr(asm.abs_l("rt_sfx_select"))
              asm.move(:w, asm.disp(0, m::EFFECT_GROUP), asm.d(0))
              asm.cmp(:w, at.call(ASKED_GROUP), asm.d(0))
              asm.branch(:ne, "rt_sfx_request_other")
              asm.tst(:w, state.call(ASKED))
              asm.branch(:ne, "rt_sfx_request_current")
              asm.tst(:w, state.call(RUNNING))
              asm.branch(:eq, "rt_sfx_request_other")
              asm.tst(:w, state.call(STOPPING))
              asm.branch(:eq, "rt_sfx_request_current")
              asm.label("rt_sfx_request_other")
              asm.addq(:w, 1, at.call(OTHER))
              asm.bra("rt_sfx_request_find")
              asm.label("rt_sfx_request_current")
              asm.move(:w, asm.disp(0, m::EFFECT_PRIORITY), asm.d(0))
              asm.cmp(:w, at.call(ASKED_PRIORITY), asm.d(0))
              asm.branch(:hi, "rt_sfx_request_none") # the one sounding outranks it
              asm.clr(:w, state.call(ASKED))
              asm.move(:w, asm.imm(1), state.call(STOPPING))
              asm.label("rt_sfx_request_ask")
              asm.move(:w, at.call(ASKED_EFFECT), asm.d(0))
              asm.jsr(asm.abs_l("rt_sfx_select"))
              asm.move(:w, asm.imm(1), state.call(ASKED))
              asm.moveq(1, asm.d(0))
              asm.rts
              asm.label("rt_sfx_request_none")
              asm.moveq(0, asm.d(0))
              asm.rts
            end

            # rt_sfx_above and rt_sfx_below: a frame's effects that outrank the tune, played before its parts,
            # and the rest, after (Reference::Player#advance). rt_sfx_above takes up first what was asked for
            # since the last frame. rt_sfx_select_ranked: the effect at place WALK of the rank order, selected,
            # its number in D0.
            def emit_passes(asm, at, count)
              m = Genesis::Music
              asm.label("rt_sfx_above")
              count.times do |effect|
                asm.move(:w, at.call(STATES, (effect * STATE_BYTES) + ASKED), at.call(STATES, (effect * STATE_BYTES) + ASKED_NOW))
                asm.clr(:w, at.call(STATES, (effect * STATE_BYTES) + ASKED))
              end
              asm.clr(:w, at.call(TUNE_RANK))
              asm.tst(:w, at.call(Music::PLAYING))
              asm.branch(:eq, "rt_sfx_above_tune")
              asm.movea(:l, at.call(Music::SONG), asm.a(0))
              asm.move(:w, asm.disp(0, m::RANK), asm.d(0))
              asm.addq(:w, 1, asm.d(0))
              asm.move(:w, asm.d(0), at.call(TUNE_RANK))
              asm.label("rt_sfx_above_tune")
              emit_pass(asm, at, count, "rt_sfx_above", above: true)

              asm.label("rt_sfx_below")
              emit_pass(asm, at, count, "rt_sfx_below", above: false)

              asm.label("rt_sfx_select_ranked")
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.move(:w, at.call(WALK), asm.d(0))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.addq(:w, 2, asm.d(0)) # past how many there are
              asm.add(:w, asm.disp(0, m::BY_RANK_AT), asm.d(0))
              Music.emit_table_place(asm, 2)
              asm.move(:w, asm.ind(2), asm.d(0))
              asm.move(:w, asm.d(0), asm.pre(M68000::SP))
              asm.jsr(asm.abs_l("rt_sfx_select"))
              asm.move(:w, asm.post(M68000::SP), asm.d(0))
              asm.rts
            end

            # One pass over the effects in rank order, playing those that outrank the tune (+above+), or those
            # that do not: an effect outranks it when its rank's place is at least TUNE_RANK.
            def emit_pass(asm, at, count, name, above:)
              asm.clr(:w, at.call(WALK))
              asm.label("#{name}_next")
              asm.jsr(asm.abs_l("rt_sfx_select_ranked"))
              asm.move(:w, asm.disp(0, Genesis::Music::EFFECT_RANK), asm.d(0))
              asm.cmp(:w, at.call(TUNE_RANK), asm.d(0))
              asm.branch(above ? :cs : :cc, "#{name}_walk") # past an effect on the other side of the tune
              asm.jsr(asm.abs_l("rt_sfx_frame"))
              asm.label("#{name}_walk")
              asm.addq(:w, 1, at.call(WALK))
              asm.cmp(:w, asm.imm(count), at.call(WALK))
              asm.branch(:cs, "#{name}_next")
              asm.rts
            end

            # rt_sfx_frame: one frame of the effect selected (Reference::Player#play_effect_frame). Cut off, it
            # stops first; asked for, it starts from its first note; at its end, it lets go of its voices;
            # sounding, each part plays its note whose frame has come, on the voice its rank lets it take.
            def emit_frame(asm, at, memory, level_at, recorded)
              m = Genesis::Music
              state = ->(field) { asm.disp(1, field) }
              asm.label("rt_sfx_frame")
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.tst(:w, state.call(STOPPING))
              asm.branch(:eq, "rt_sfx_frame_not_cut")
              asm.clr(:w, state.call(STOPPING))
              asm.jsr(asm.abs_l("rt_sfx_finish"))
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.label("rt_sfx_frame_not_cut")
              asm.tst(:w, state.call(ASKED_NOW))
              asm.branch(:eq, "rt_sfx_frame_not_asked")
              asm.move(:w, asm.imm(1), state.call(RUNNING))
              asm.clr(:w, state.call(FRAME))
              m::PARTS.times { |part| asm.clr(:w, state.call(CURSORS + (part * 2))) }
              Music.emit_group_at(asm, at.call(RECORD), m::EFFECT_START_LOG)
              asm.bra("rt_sfx_frame_sounding")
              asm.label("rt_sfx_frame_not_asked")
              asm.tst(:w, state.call(RUNNING))
              asm.branch(:eq, "rt_sfx_frame_sounding")
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, state.call(FRAME), asm.d(0))
              asm.cmp(:w, asm.disp(0, m::EFFECT_LENGTH), asm.d(0))
              asm.branch(:cs, "rt_sfx_frame_sounding")
              asm.jsr(asm.abs_l("rt_sfx_finish"))
              asm.label("rt_sfx_frame_sounding")
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.tst(:w, state.call(RUNNING))
              asm.branch(:ne, "rt_sfx_frame_parts")
              asm.rts
              asm.label("rt_sfx_frame_parts")
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_PART_COUNT), at.call(PARTS))
              asm.clr(:w, at.call(PART))
              asm.label("rt_sfx_frame_part")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, at.call(PARTS), asm.d(0))
              asm.branch(:cc, "rt_sfx_frame_done")
              asm.jsr(asm.abs_l("rt_sfx_entry"))
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.move(:w, at.call(PART), asm.d(1)) # its next note
              asm.add(:w, asm.d(1), asm.d(1))
              asm.move(:w, asm.idx(1, CURSORS, 1, :w), asm.d(0))
              asm.cmp(:w, asm.disp(0, m::NOTE_COUNT), asm.d(0))
              asm.branch(:cc, "rt_sfx_frame_next")
              asm.mulu(asm.imm(m::NOTE_BYTES), asm.d(0))
              asm.moveq(0, asm.d(2))
              asm.move(:w, asm.disp(0, m::NOTES_AT), asm.d(2))
              asm.add(:l, asm.d(2), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.lea(asm.idx(0, 0, 0), asm.a(2))
              asm.move(:l, asm.a(2), at.call(NOTE))
              asm.move(:w, asm.disp(2, m::NOTE_FRAME), asm.d(0))
              asm.cmp(:w, state.call(FRAME), asm.d(0))
              asm.branch(:ne, "rt_sfx_frame_next")
              asm.addq(:w, 1, asm.idx(1, CURSORS, 1, :w))
              if recorded # a part that plays a recording: its note in Recordings' place
                asm.movea(:l, at.call(ENTRY), asm.a(0))
                asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
                asm.cmp(:w, asm.imm(m::RECORDED_CHANNEL), asm.d(0))
                asm.branch(:cs, "rt_sfx_frame_console")
                asm.jsr(asm.abs_l("rt_sfx_recorded_note"))
                asm.bra("rt_sfx_frame_next")
                asm.label("rt_sfx_frame_console")
              end
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_RANK), asm.d(0))
              emit_claim_call(asm, at, entry: ENTRY, note: NOTE)
              asm.branch(:eq, "rt_sfx_frame_next")
              if level_at # the tune's note there is no longer held for a new level to reach
                asm.move(:w, at.call(CLAIM_CHANNEL), asm.d(0))
                asm.jsr(asm.abs_l("rt_music_unhold"))
              end
              Music.emit_group_at(asm, at.call(NOTE), m::NOTE_HEAD)
              Music.emit_group_at(asm, at.call(NOTE), m::NOTE_TAIL)
              # An effect's note changes as it plays as a tune's does, by the same steps, which read the note
              # from the tune's places (Reference::Player#set_voice). The tune's own walk has finished or not
              # begun whenever an effect plays, so those places are free.
              asm.move(:l, at.call(ENTRY), at.call(Music::ENTRY))
              asm.move(:l, at.call(NOTE), at.call(Music::NOTE))
              Music.emit_note_changes(asm, memory)
              asm.label("rt_sfx_frame_next")
              asm.addq(:w, 1, at.call(PART))
              asm.bra("rt_sfx_frame_part")
              asm.label("rt_sfx_frame_done")
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.addq(:w, 1, state.call(FRAME))
              asm.rts

              # rt_sfx_entry: ENTRY and A0 = where part PART of the effect selected is.
              asm.label("rt_sfx_entry")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.mulu(asm.imm(m::PART_BYTES), asm.d(0))
              asm.add(:l, at.call(RECORD), asm.d(0))
              asm.add(:l, asm.imm(m::EFFECT_RECORD_BYTES), asm.d(0))
              asm.move(:l, asm.d(0), at.call(ENTRY))
              asm.movea(:l, asm.d(0), asm.a(0))
              asm.rts
            end

            # rt_sfx_finish: the effect selected over (Reference::Player#finish_effect): not sounding, and every
            # voice it still holds free and quiet, in the order the voices were first held, each through its
            # part's group for letting the voice go; then, with +recorded+, each part that plays a recording
            # gives back the place it still sounds a note in.
            def emit_finish(asm, at, memory, recorded)
              m = Genesis::Music
              asm.label("rt_sfx_finish")
              asm.movea(:l, at.call(STATE), asm.a(1))
              asm.clr(:w, asm.disp(1, RUNNING))
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_RANK), at.call(RELEASE_RANK))
              asm.clr(:w, at.call(RELEASE_WALK))
              asm.label("rt_sfx_finish_next")
              asm.move(:w, at.call(RELEASE_WALK), asm.d(1))
              asm.cmp(:w, at.call(HOLDER_END), asm.d(1))
              asm.branch(:cc, "rt_sfx_finish_done")
              asm.lea(at.call(HOLDER_ORDER), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 1, :w), asm.d(0))
              asm.move(:w, asm.d(0), at.call(RELEASE_CHANNEL))
              asm.subq(:w, 1, asm.d(0))
              asm.move(:w, asm.d(0), asm.d(4))
              asm.lsl(:w, 3, asm.d(4)) # VOICE_BYTES a voice, for the steps of a note that changes
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(at.call(HOLDERS), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 0, :w), asm.d(1))
              asm.cmp(:w, at.call(RELEASE_RANK), asm.d(1))
              asm.branch(:ne, "rt_sfx_finish_walk")
              asm.clr(:w, asm.idx(1, 0, 0, :w))
              Music.emit_voice_stops_changing(asm, at, memory, at.call(RELEASE_CHANNEL))
              # Its part on that voice, whose group lets the voice go.
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_PART_COUNT), at.call(PARTS))
              asm.clr(:w, at.call(PART))
              asm.label("rt_sfx_finish_find")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, at.call(PARTS), asm.d(0))
              asm.branch(:cc, "rt_sfx_finish_walk")
              asm.jsr(asm.abs_l("rt_sfx_entry"))
              asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
              asm.cmp(:w, at.call(RELEASE_CHANNEL), asm.d(0))
              asm.branch(:eq, "rt_sfx_finish_found")
              asm.addq(:w, 1, at.call(PART))
              asm.bra("rt_sfx_finish_find")
              asm.label("rt_sfx_finish_found")
              Music.emit_group_at(asm, at.call(ENTRY), m::EFFECT_RELEASE)
              asm.label("rt_sfx_finish_walk")
              asm.addq(:w, 2, at.call(RELEASE_WALK))
              asm.bra("rt_sfx_finish_next")
              asm.label("rt_sfx_finish_done")
              asm.jmp(asm.abs_l("rt_sfx_release_recorded")) if recorded
              asm.rts unless recorded
            end

            # rt_sfx_recorded_note: the note at NOTE of the selected effect's part that plays a recording, D0 its
            # channel, in a place the effect owns (Recordings::EFFECT_OWNER): a note takes the place at the
            # effect's rank and logs itself if it found it; a note that sounds nothing gives the part's place
            # back, and logs itself only if the part had it (Reference::Player#play_effect_frame).
            #
            # rt_sfx_release_recorded: each of the selected effect's parts that plays a recording gives back the
            # place it still sounds a note in, logging its end through its release group if it had one
            # (Reference::Player#finish_effect).
            #
            # rt_sfx_owner: D1 = the owner number of the effect's part on channel D0.
            def emit_recorded_parts(asm, at)
              m = Genesis::Music
              asm.label("rt_sfx_recorded_note")
              asm.jsr(asm.abs_l("rt_sfx_owner"))
              asm.movea(:l, at.call(NOTE), asm.a(0))
              asm.move(:w, asm.disp(0, m::NOTE_RECORDING), asm.d(0))
              asm.branch(:ne, "rt_sfx_recorded_note_plays")
              asm.move(:w, asm.d(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_recordings_note_release"))
              asm.bra("rt_sfx_recorded_note_heard")
              asm.label("rt_sfx_recorded_note_plays")
              asm.subq(:w, 1, asm.d(0))
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_RANK), asm.d(2))
              asm.addq(:w, 1, asm.d(2)) # above the game's own sounds, at nought
              asm.jsr(asm.abs_l("rt_recordings_note"))
              asm.label("rt_sfx_recorded_note_heard")
              asm.tst(:w, asm.d(0))
              asm.branch(:eq, "rt_sfx_recorded_note_done")
              Music.emit_group_at(asm, at.call(NOTE), m::NOTE_HEAD)
              asm.label("rt_sfx_recorded_note_done")
              asm.rts

              asm.label("rt_sfx_release_recorded")
              asm.movea(:l, at.call(RECORD), asm.a(0))
              asm.move(:w, asm.disp(0, m::EFFECT_PART_COUNT), at.call(PARTS))
              asm.clr(:w, at.call(PART))
              asm.label("rt_sfx_release_recorded_part")
              asm.move(:w, at.call(PART), asm.d(0))
              asm.cmp(:w, at.call(PARTS), asm.d(0))
              asm.branch(:cc, "rt_sfx_release_recorded_done")
              asm.jsr(asm.abs_l("rt_sfx_entry"))
              asm.move(:w, asm.disp(0, m::CHANNEL), asm.d(0))
              asm.cmp(:w, asm.imm(m::RECORDED_CHANNEL), asm.d(0))
              asm.branch(:cs, "rt_sfx_release_recorded_next") # a voice of the console's own, let go above
              asm.jsr(asm.abs_l("rt_sfx_owner"))
              asm.move(:w, asm.d(1), asm.d(0))
              asm.jsr(asm.abs_l("rt_recordings_note_release"))
              asm.tst(:w, asm.d(0))
              asm.branch(:eq, "rt_sfx_release_recorded_next")
              Music.emit_group_at(asm, at.call(ENTRY), m::EFFECT_RELEASE)
              asm.label("rt_sfx_release_recorded_next")
              asm.addq(:w, 1, at.call(PART))
              asm.bra("rt_sfx_release_recorded_part")
              asm.label("rt_sfx_release_recorded_done")
              asm.rts

              asm.label("rt_sfx_owner")
              asm.sub(:w, asm.imm(m::RECORDED_CHANNEL - 1), asm.d(0)) # its place among the effect's recorded parts, one up
              asm.move(:w, at.call(EFFECT), asm.d(1))
              asm.addq(:w, 1, asm.d(1))
              asm.lsl(:w, 8, asm.d(1)) # the effect's number, one up, in the high byte
              asm.or(:w, asm.d(0), asm.d(1))
              asm.rts
            end

            # rt_sfx_claim: may a note of rank CLAIM_RANK sound on CLAIM_CHANNEL? Yes (D0 = 1) when nobody
            # holding it outranks it, and then it holds the voice while it sounds (CLAIM_SOUNDS), where a rest
            # lets it go; nought otherwise (Reference::Player#claim_channel).
            def emit_claim_routine(asm, at)
              asm.label("rt_sfx_claim")
              asm.move(:w, at.call(CLAIM_CHANNEL), asm.d(1))
              asm.subq(:w, 1, asm.d(1))
              asm.add(:w, asm.d(1), asm.d(1))
              asm.lea(at.call(HOLDERS), asm.a(1))
              asm.move(:w, asm.idx(1, 0, 1, :w), asm.d(0))
              asm.cmp(:w, at.call(CLAIM_RANK), asm.d(0))
              asm.branch(:hi, "rt_sfx_claim_refused")
              asm.moveq(0, asm.d(0))
              asm.tst(:w, at.call(CLAIM_SOUNDS))
              asm.branch(:eq, "rt_sfx_claim_hold")
              asm.move(:w, at.call(CLAIM_RANK), asm.d(0))
              asm.label("rt_sfx_claim_hold")
              asm.move(:w, asm.d(0), asm.idx(1, 0, 1, :w))
              asm.lea(at.call(HOLDER_SEEN), asm.a(1))
              asm.tst(:w, asm.idx(1, 0, 1, :w))
              asm.branch(:ne, "rt_sfx_claim_known")
              asm.move(:w, asm.imm(1), asm.idx(1, 0, 1, :w))
              asm.move(:w, at.call(HOLDER_END), asm.d(1))
              asm.lea(at.call(HOLDER_ORDER), asm.a(1))
              asm.move(:w, at.call(CLAIM_CHANNEL), asm.idx(1, 0, 1, :w))
              asm.addq(:w, 2, at.call(HOLDER_END))
              asm.label("rt_sfx_claim_known")
              asm.moveq(1, asm.d(0))
              asm.rts
              asm.label("rt_sfx_claim_refused")
              asm.moveq(0, asm.d(0))
              asm.rts
            end

            # rt_sfx_select: the effect numbered D0 selected: EFFECT, RECORD and A0 where its record is, STATE
            # and A1 where its state is.
            def emit_select(asm, at)
              asm.label("rt_sfx_select")
              asm.move(:w, asm.d(0), at.call(EFFECT))
              asm.move(:w, asm.d(0), asm.d(1))
              asm.mulu(asm.imm(STATE_BYTES), asm.d(1))
              asm.lea(at.call(STATES), asm.a(1))
              asm.lea(asm.idx(1, 0, 1), asm.a(1))
              asm.move(:l, asm.a(1), at.call(STATE))
              asm.add(:w, asm.d(0), asm.d(0))
              asm.lea(asm.abs_l("music_data"), asm.a(0))
              asm.add(:w, asm.disp(0, Genesis::Music::EFFECTS_AT), asm.d(0))
              Music.emit_table_place(asm, 2)
              asm.move(:w, asm.ind(2), asm.d(0))
              Music.emit_table_place(asm, 2)
              asm.move(:l, asm.a(2), at.call(RECORD))
              asm.movea(:l, asm.a(2), asm.a(0))
              asm.rts
            end
          end
        end
      end
    end
  end
end
