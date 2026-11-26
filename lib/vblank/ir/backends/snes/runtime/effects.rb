# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # The sound effects player, beside the tune's (Music), the same steps as
          # Reference::Player's, in its order.
          #
          # The game asks for an effect (rt_sfx_play); at the next frame it starts from its first
          # note, plays each note once as its frame comes, and at its end lets go of the voices it
          # still holds, quieting them. The tune and the effects share the console's four voices, and
          # who sounds on one is settled by rank (SNES::Music, "who sounds on a voice"): a note takes a
          # voice whose holder's rank is no higher than its own, and holds it while it makes a sound
          # (rt_sfx_claim). Each frame plays the effects that outrank the tune before the tune's parts
          # and the rest after, so whoever writes a voice first on a frame is whoever keeps it.
          #
          # An effect in a group plays one at a time with the rest of its group: asked for while
          # another of its group is sounding or already asked for, it is not played if its priority
          # is lower, and otherwise stops that one on the next frame and starts in its place
          # (Reference::Player#request_effect).
          module Effects
            # Which voice each holder holds, by channel (1..4, two bytes each from channel 1): the
            # holder's rank's place; and the channels in the order each was first held, as the
            # interpreter's Hash keeps them, which is the order an effect's end lets them go in.
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
            # The effect being played: its number, where its record is, where its state is, the part
            # being played and how many, that part's entry and its note.
            EFFECT = "rt sfx effect"
            RECORD = "rt sfx record"
            STATE = "rt sfx state"
            PART = "rt sfx part"
            PARTS = "rt sfx parts"
            ENTRY = "rt sfx entry"
            NOTE = "rt sfx note"
            # Where in HOLDER_ORDER an effect's end is, apart from LIVE_AT, since an effect is ended in
            # the middle of a walk through LIVE.
            RELEASE_WALK = "rt sfx release walk"
            # An effect's end: its rank's place, and the voice it is letting go.
            RELEASE_RANK = "rt sfx release rank"
            RELEASE_CHANNEL = "rt sfx release channel"
            # An effect asked for: its number, group and priority.
            ASKED_EFFECT = "rt sfx asked effect"
            ASKED_GROUP = "rt sfx asked group"
            ASKED_PRIORITY = "rt sfx asked priority"
            # For each group, a word from group 1's at the second word: the effect of the group asked
            # for last and not refused, one up, nought for none yet (rt_sfx_request).
            GROUP_LAST = "rt sfx group last"
            # Where a table being read is in the song table (an effect list, the ranks' kinds).
            TABLE_AT = "rt sfx table at"
            # Each effect's state, STATE_BYTES apart: asked for since the last frame; asked for, as a
            # frame plays it; to be cut off; sounding; how far into it; each part's next note.
            STATES = "rt sfx states"
            ASKED = 0
            ASKED_NOW = 2
            STOPPING = 4
            RUNNING = 6
            FRAME = 8
            CURSORS = 10
            STATE_BYTES = 64 # Past CURSORS and a word for each of the most parts an effect has
            # The effects a frame has to look at, by number, each one up, the highest rank first, and
            # nought after the last; and beside each, in LIVE_RANKS, its rank's place, which keeps the
            # order. A word an effect. An effect asked for goes in as it is asked (rt_sfx_live_add);
            # LIVE_CHANGED marks that one ended, so the next frame leaves out those that are over
            # (rt_sfx_live_prune). LIVE_AT walks it, and LIVE_KEPT is where the pruning writes.
            LIVE = "rt sfx live"
            LIVE_RANKS = "rt sfx live ranks"
            LIVE_AT = "rt sfx live at"
            LIVE_KEPT = "rt sfx live kept"
            LIVE_CHANGED = "rt sfx live changed"
            # The effect going in, one up, and its rank's place.
            LIVE_EFFECT = "rt sfx live effect"
            LIVE_RANK = "rt sfx live rank"

            CHANNELS = (1..4).freeze

            # Which of the sound chip's voices the game's sound effects hold, read off a running
            # cartridge by a reader that has the build's record (Diagnostics::SNESReading#sound_effect_voices).
            #
            # An effect's notes do not keep to one voice. A part of the console's own kind (a square,
            # the wave, the noise) plays on its channel's voice (DSPWrites::CHANNEL_VOICES) while the
            # effect holds that channel, which HOLDERS says by rank: +effect_ranks+ is the places in
            # the rank order that are effects' (SongTable#effect_rank_places). A part that plays a
            # recording takes a place of Recordings each note, whichever is free or ranks lowest, and
            # the place sounds on its voice (+recording_voices+, the first place's first): an effect
            # holds the place while it is not free and its owner is an effect's (Recordings::OWNER,
            # EFFECT_OWNER and over), its note's fall included.
            #
            # Nothing here is in the cartridge: it is worked out from the build, so a game's bytes are
            # the same whether or not a test asks.
            HeldVoices = Data.define(:effect_ranks, :recording_voices) do
              # The voices, by number, the effects hold as +runtime+ (the build's runtime places) and
              # +read16+ (a word of work RAM at an address) show them now, lowest first.
              def voices(runtime, &read16)
                (console_voices(runtime, &read16) + recorded_voices(runtime, &read16)).uniq.sort
              end

              private

              def console_voices(runtime)
                at = runtime[HOLDERS] or return []
                CHANNELS.select { |channel| effect_ranks.include?(yield(at + ((channel - 1) * 2))) }
                        .map { |channel| DSPWrites::CHANNEL_VOICES.fetch(channel) }
              end

              def recorded_voices(runtime)
                at = runtime[Recordings::PLACES_STATE] or return []
                recording_voices.each_with_index.select do |_, place|
                  state = at + (place * Recordings::PLACE_BYTES)
                  yield(state + Recordings::HELD).nonzero? && yield(state + Recordings::OWNER) >= Recordings::EFFECT_OWNER
                end.map(&:first)
              end
            end

            module_function

            def reserve(memory, effects)
              [HOLDER_END, CLAIM_CHANNEL, CLAIM_RANK, CLAIM_SOUNDS, TUNE_RANK, EFFECT, RECORD, STATE, PART, PARTS,
               ENTRY, NOTE, RELEASE_WALK, RELEASE_RANK, RELEASE_CHANNEL, ASKED_EFFECT, ASKED_GROUP, ASKED_PRIORITY,
               TABLE_AT, LIVE_AT, LIVE_KEPT, LIVE_CHANGED, LIVE_EFFECT, LIVE_RANK].each { |name| memory.reserve(name, 2) }
              [HOLDERS, HOLDER_ORDER, HOLDER_SEEN].each { |name| memory.reserve(name, CHANNELS.size * 2) }
              memory.reserve(STATES, effects * STATE_BYTES)
              # Every effect and the nought after; and a group for each effect at most, past a word
              # for no group.
              [LIVE, LIVE_RANKS, GROUP_LAST].each { |name| memory.reserve(name, (effects + 1) * 2) }
            end

            # +level_at+ is where the game's music volume is, if it sets one, since an effect taking a
            # voice takes the tune's note there out of those a new level reaches.
            # +recorded+ when a song or effect has a part that plays a recording.
            #
            # Nothing here walks every effect the game declares. A request goes straight to its
            # effect by number, as a console's own sound drivers take a sound's number from the APU
            # ports and go to its entry (fullsnes, "SNES APU Main CPU Communication Port"), so the
            # time an effect takes to start, and the sample its note starts on, do not grow with the
            # effects a game has. A frame walks only the effects in LIVE.
            def emit(asm, memory, level_at, recorded: false)
              at = ->(name, plus = 0) { asm.abs(memory[name], plus) }
              emit_game_side(asm, at, memory)
              emit_live_list(asm, at, memory)
              emit_passes(asm, at, memory)
              emit_frame(asm, at, memory, level_at, recorded)
              emit_finish(asm, at, memory, recorded)
              emit_recorded_parts(asm, at, memory) if recorded
              emit_claim_routine(asm, at, memory)
              emit_select(asm, at, memory)
              emit_effect_holds(asm, at, memory)
            end

            # A call of rt_sfx_claim, inline, by the rank's place in A, for the part whose entry is at
            # +entry+ and its note at +note+ (places in work RAM holding where each is in the table).
            # A = 1 when the note takes the voice, nought when a holder of a higher rank keeps it.
            def emit_claim_call(asm, memory, entry: Music::ENTRY, note: Music::NOTE)
              m = SNES::Music
              asm.sta(asm.abs(memory[CLAIM_RANK]))
              asm.ldx(asm.abs(memory[entry]))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.sta(asm.abs(memory[CLAIM_CHANNEL]))
              if note == Music::NOTE
                Music.emit_note_field(asm, memory, m::NOTE_SOUNDS)
              else
                asm.ldx(asm.abs(memory[note]))
                asm.lda(asm.long_x("music_data", m::NOTE_SOUNDS))
              end
              asm.sta(asm.abs(memory[CLAIM_SOUNDS]))
              asm.jsr(asm.abs("rt_sfx_claim"))
            end

            # rt_sfx_effect_holds (JSR): A, and the zero flag clear, when a sound effect holds the voice
            # Y names (two bytes a voice, from channel 1), rather than the tune or nobody. Y is kept.
            def emit_effect_holds(asm, at, memory)
              asm.label("rt_sfx_effect_holds")
              asm.lda(asm.long("music_data", SNES::Music::RANK_KINDS_AT))
              asm.sta(at.call(TABLE_AT))
              asm.lda(asm.abs_y(memory[HOLDERS]))
              asm.asl
              asm.clc
              asm.adc(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.rts
            end

            # As the tune stops, inline: R0, the voices its parts play on, less those a sound effect
            # holds; and every voice the tune holds, or nobody does, free
            # (Reference::Player#silence_song).
            def emit_release_tune_voices(asm, memory)
              asm.lda(asm.long("music_data", SNES::Music::RANK_KINDS_AT))
              asm.sta(asm.abs(memory[TABLE_AT])) # where the ranks' kinds are
              CHANNELS.each do |channel|
                kept = "rt_music_quiet_kept_#{channel}"
                done = "rt_music_quiet_done_#{channel}"
                holder = asm.abs(memory[HOLDERS], (channel - 1) * 2)
                asm.lda(holder)
                asm.asl
                asm.clc
                asm.adc(asm.abs(memory[TABLE_AT]))
                asm.tax
                asm.lda(asm.long_x("music_data"))
                asm.bne(kept)
                asm.stz(holder)
                asm.bra(done)
                asm.label(kept) # an effect's: not let go
                asm.lda(asm.direct(Sound::R0))
                asm.and_a(~(1 << DSPWrites::CHANNEL_VOICES.fetch(channel)) & 0xFFFF)
                asm.sta(asm.direct(Sound::R0))
                asm.label(done)
              end
            end

            # rt_sfx_play(which, list): the effect at place +which+ of effect list +list+ starts at the
            # next frame (Reference::Player#request_effect); rt_sfx_play_now, here
            # (Reference::Player#start_effect_here).
            def emit_game_side(asm, at, memory)
              m = SNES::Music
              asm.label("rt_sfx_play")
              asm.jsr(asm.abs("rt_sfx_request"))
              asm.rtl

              asm.label("rt_sfx_play_now")
              asm.jsr(asm.abs("rt_sfx_request"))
              asm.bne("rt_sfx_play_now_asked")
              asm.rtl
              asm.label("rt_sfx_play_now_asked")
              asm.lda(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              # The live effects, in rank order: this one plays its first frame; one of a group
              # waiting to be cut off is cut off here. Every effect waiting to be cut off is live.
              emit_live_walk(asm, at, memory, "rt_sfx_play_now") do
                asm.lda(at.call(EFFECT))
                asm.cmp(at.call(ASKED_EFFECT))
                asm.bne("rt_sfx_play_now_other")
                asm.lda(1)
                asm.sta(asm.abs_y(memory[STATES], ASKED_NOW))
                asm.jsr(asm.abs("rt_sfx_frame"))
                asm.ldy(at.call(STATE))
                asm.lda(0)
                asm.sta(asm.abs_y(memory[STATES], ASKED_NOW))
                asm.bra("rt_sfx_play_now_walk")
                asm.label("rt_sfx_play_now_other")
                asm.lda(asm.abs_y(memory[STATES], STOPPING))
                asm.beq("rt_sfx_play_now_walk")
                asm.lda(0)
                asm.sta(asm.abs_y(memory[STATES], STOPPING))
                asm.lda(1)
                asm.sta(at.call(Sound::ASKING_AHEAD)) # let go ahead of the song, as what cuts it is
                asm.jsr(asm.abs("rt_sfx_finish"))
                asm.stz(at.call(Sound::ASKING_AHEAD))
                asm.label("rt_sfx_play_now_walk")
              end
              asm.rtl

              # rt_sfx_request: the effect at place R0 (32 bits) of list R1 asked for, A = 1 and
              # ASKED_EFFECT its number; or A = nought, for a place outside the list or an effect its
              # group's sounding one outranks.
              #
              # The interpreter looks through the effects in the order declared for the first of the
              # group asked for, or sounding and not being cut off (Reference::Player#request_effect).
              # There is never more than one: asking for an effect of a group either cuts that one off
              # or is refused. So it is always the one asked for last and not refused, if it is still
              # asked for or sounding, and GROUP_LAST names it without a walk.
              asm.label("rt_sfx_request")
              asm.lda(asm.direct(Sound::R0 + 2))
              asm.branch_long(:bne, "rt_sfx_request_none")
              asm.lda(asm.direct(Sound::R1))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", m::EFFECT_LISTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.direct(Sound::R0))
              asm.cmp(asm.long_x("music_data")) # how many effects the list holds
              asm.branch_long(:bcs, "rt_sfx_request_none")
              asm.asl
              asm.clc
              asm.adc(at.call(TABLE_AT))
              asm.tax
              asm.lda(asm.long_x("music_data", 2))
              asm.sta(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(asm.long_x("music_data", m::EFFECT_GROUP))
              asm.beq("rt_sfx_request_ask")
              asm.sta(at.call(ASKED_GROUP))
              asm.lda(asm.long_x("music_data", m::EFFECT_PRIORITY))
              asm.sta(at.call(ASKED_PRIORITY))
              # The one of its group asked for last, if it is asked for or sounding and not stopping.
              asm.lda(at.call(ASKED_GROUP))
              asm.asl
              asm.tax
              asm.lda(asm.abs_x(memory[GROUP_LAST]))
              asm.beq("rt_sfx_request_ask")
              asm.dec
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(asm.abs_y(memory[STATES], ASKED))
              asm.bne("rt_sfx_request_current")
              asm.lda(asm.abs_y(memory[STATES], RUNNING))
              asm.beq("rt_sfx_request_ask")
              asm.lda(asm.abs_y(memory[STATES], STOPPING))
              asm.bne("rt_sfx_request_ask")
              asm.label("rt_sfx_request_current")
              asm.lda(asm.long_x("music_data", m::EFFECT_PRIORITY))
              asm.cmp(at.call(ASKED_PRIORITY))
              asm.beq("rt_sfx_request_cut")
              asm.bcs("rt_sfx_request_none") # the one sounding outranks it
              asm.label("rt_sfx_request_cut")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              asm.lda(1)
              asm.sta(asm.abs_y(memory[STATES], STOPPING))
              asm.label("rt_sfx_request_ask")
              asm.lda(at.call(ASKED_EFFECT))
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(1)
              asm.sta(asm.abs_y(memory[STATES], ASKED))
              asm.lda(asm.long_x("music_data", m::EFFECT_GROUP))
              asm.beq("rt_sfx_request_live")
              asm.asl
              asm.tay
              asm.lda(at.call(ASKED_EFFECT))
              asm.inc
              asm.sta(asm.abs_y(memory[GROUP_LAST]))
              asm.label("rt_sfx_request_live")
              asm.jsr(asm.abs("rt_sfx_live_add"))
              asm.lda(1)
              asm.rts
              asm.label("rt_sfx_request_none")
              asm.lda(0)
              asm.rts
            end

            # rt_sfx_live_add: the effect selected, number ASKED_EFFECT, in LIVE in its place by rank,
            # unless it is there already. The walk is over the live effects alone, the few sounding.
            #
            # rt_sfx_live_prune: the effects of LIVE no longer asked for, sounding or to be cut off,
            # left out, the rest kept in their order.
            def emit_live_list(asm, at, memory)
              live = ->(plus = 0) { asm.abs_x(memory[LIVE], plus) }
              ranks = ->(plus = 0) { asm.abs_x(memory[LIVE_RANKS], plus) }
              asm.label("rt_sfx_live_add")
              asm.lda(at.call(ASKED_EFFECT))
              asm.inc
              asm.sta(at.call(LIVE_EFFECT))
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", SNES::Music::EFFECT_RANK))
              asm.sta(at.call(LIVE_RANK))
              asm.ldx(0)
              asm.label("rt_sfx_live_add_find")
              asm.lda(live.call)
              asm.beq("rt_sfx_live_add_last")
              asm.cmp(at.call(LIVE_EFFECT))
              asm.beq("rt_sfx_live_add_done") # live already
              asm.lda(ranks.call)
              asm.cmp(at.call(LIVE_RANK))
              asm.bcc("rt_sfx_live_add_before") # it ranks below the new one, which goes before it
              asm.inx
              asm.inx
              asm.bra("rt_sfx_live_add_find")
              # Each from the nought at the end back to this place one word along.
              asm.label("rt_sfx_live_add_before")
              asm.stx(at.call(LIVE_AT))
              asm.label("rt_sfx_live_add_end")
              asm.inx
              asm.inx
              asm.lda(live.call)
              asm.bne("rt_sfx_live_add_end")
              asm.label("rt_sfx_live_add_move")
              asm.lda(live.call)
              asm.sta(live.call(2))
              asm.lda(ranks.call)
              asm.sta(ranks.call(2))
              asm.cpx(at.call(LIVE_AT))
              asm.beq("rt_sfx_live_add_place")
              asm.dex
              asm.dex
              asm.bra("rt_sfx_live_add_move")
              asm.label("rt_sfx_live_add_last")
              asm.stz(live.call(2))
              asm.label("rt_sfx_live_add_place")
              asm.lda(at.call(LIVE_EFFECT))
              asm.sta(live.call)
              asm.lda(at.call(LIVE_RANK))
              asm.sta(ranks.call)
              asm.label("rt_sfx_live_add_done")
              asm.rts

              asm.label("rt_sfx_live_prune")
              asm.stz(at.call(LIVE_CHANGED))
              asm.stz(at.call(LIVE_AT))
              asm.stz(at.call(LIVE_KEPT))
              asm.label("rt_sfx_live_prune_next")
              asm.ldx(at.call(LIVE_AT))
              asm.lda(live.call)
              asm.beq("rt_sfx_live_prune_done")
              asm.dec
              asm.jsr(asm.abs("rt_sfx_select"))
              asm.lda(asm.abs_y(memory[STATES], ASKED))
              asm.ora(asm.abs_y(memory[STATES], RUNNING))
              asm.ora(asm.abs_y(memory[STATES], STOPPING))
              asm.beq("rt_sfx_live_prune_past")
              asm.ldx(at.call(LIVE_AT))
              asm.lda(ranks.call)
              asm.pha
              asm.lda(live.call)
              asm.ldx(at.call(LIVE_KEPT))
              asm.sta(live.call)
              asm.pla
              asm.sta(ranks.call)
              asm.inc(at.call(LIVE_KEPT))
              asm.inc(at.call(LIVE_KEPT))
              asm.label("rt_sfx_live_prune_past")
              asm.inc(at.call(LIVE_AT))
              asm.inc(at.call(LIVE_AT))
              asm.bra("rt_sfx_live_prune_next")
              asm.label("rt_sfx_live_prune_done")
              asm.ldx(at.call(LIVE_KEPT))
              asm.stz(live.call)
              asm.rts
            end

            # rt_sfx_above and rt_sfx_below: a frame's effects that outrank the tune, played before its
            # parts, and the rest, after (Reference::Player#advance). rt_sfx_above takes up first what
            # was asked for since the last frame.
            def emit_passes(asm, at, memory)
              m = SNES::Music
              asm.label("rt_sfx_above")
              asm.lda(at.call(LIVE_CHANGED))
              asm.beq("rt_sfx_above_live_known")
              asm.jsr(asm.abs("rt_sfx_live_prune"))
              asm.label("rt_sfx_above_live_known")
              asm.lda(asm.abs(memory[LIVE]))
              asm.bne("rt_sfx_above_live")
              asm.rts # nothing live: nothing here or in rt_sfx_below has a thing to do
              asm.label("rt_sfx_above_live")
              # Taken up once a frame: with the effects on a timer rt_sfx_above is called again for the
              # tick (Music#emit_effect_pass), after the effects below the tune still have theirs to start.
              if memory.reserved?(Music::EFFECTS_STARTING)
                asm.lda(asm.abs(memory[Music::EFFECTS_STARTING]))
                asm.branch_long(:beq, "rt_sfx_asked_live_done")
              end
              emit_live_walk(asm, at, memory, "rt_sfx_asked") do
                asm.lda(asm.abs_y(memory[STATES], ASKED))
                asm.sta(asm.abs_y(memory[STATES], ASKED_NOW))
                asm.lda(0)
                asm.sta(asm.abs_y(memory[STATES], ASKED))
              end
              asm.stz(at.call(TUNE_RANK))
              asm.lda(at.call(Music::PLAYING))
              asm.beq("rt_sfx_above_tune")
              asm.ldx(at.call(Music::SONG))
              asm.lda(asm.long_x("music_data", m::RANK))
              asm.inc
              asm.sta(at.call(TUNE_RANK))
              asm.label("rt_sfx_above_tune")
              emit_pass(asm, at, memory, "rt_sfx_above", above: true)
              asm.rts

              asm.label("rt_sfx_below")
              emit_pass(asm, at, memory, "rt_sfx_below", above: false)
              asm.rts
            end

            # One pass over the live effects in rank order, playing those that outrank the tune
            # (+above+), or those that do not: an effect outranks it when its rank's place is at least
            # TUNE_RANK.
            def emit_pass(asm, at, memory, name, above:)
              emit_live_walk(asm, at, memory, name) do
                asm.lda(asm.long_x("music_data", SNES::Music::EFFECT_RANK))
                asm.cmp(at.call(TUNE_RANK))
                asm.branch_long(above ? :bcc : :bcs, "#{name}_walk") # past an effect on the other side of the tune
                asm.jsr(asm.abs("rt_sfx_frame"))
                asm.label("#{name}_walk")
              end
            end

            # The block, inline, for each effect of LIVE, selected. Going by LIVE is what makes an
            # effect nothing has asked for cost a frame nothing: every frame walks both sides of the
            # tune, and selecting an effect is a good many instructions. An effect that ends on the
            # way stays in LIVE until the next frame, and a turn of the block over it does nothing.
            def emit_live_walk(asm, at, memory, name)
              asm.stz(at.call(LIVE_AT))
              asm.label("#{name}_live_next")
              asm.ldx(at.call(LIVE_AT))
              asm.lda(asm.abs_x(memory[LIVE]))
              asm.branch_long(:beq, "#{name}_live_done")
              asm.dec
              asm.jsr(asm.abs("rt_sfx_select"))
              yield
              asm.inc(at.call(LIVE_AT))
              asm.inc(at.call(LIVE_AT))
              asm.brl("#{name}_live_next")
              asm.label("#{name}_live_done")
            end

            # rt_sfx_frame: one frame of the effect selected (Reference::Player#play_effect_frame).
            # Cut off, it stops first; asked for, it starts from its first note; at its end, it lets
            # go of its voices; sounding, each part plays its note whose frame has come, on the voice
            # its rank lets it take. With the effects on a timer, one asked for is started by a pass of
            # its own, at once (Music::EFFECTS_STARTING), which plays nothing else, and moves on from
            # its first frame on the tick's pass.
            def emit_frame(asm, at, memory, level_at, recorded)
              m = SNES::Music
              state = ->(field) { asm.abs_y(memory[STATES], field) }
              asm.label("rt_sfx_frame")
              asm.lda(1)
              asm.sta(at.call(Sound::ASKING_AHEAD)) # what it asks of the chip goes ahead of a song's
              asm.jsr(asm.abs("rt_sfx_frame_played"))
              asm.stz(at.call(Sound::ASKING_AHEAD))
              asm.rts
              timed = memory.reserved?(Music::EFFECTS_STARTING)
              asm.label("rt_sfx_frame_played")
              asm.lda(state.call(STOPPING))
              asm.beq("rt_sfx_frame_not_cut")
              asm.lda(0)
              asm.sta(state.call(STOPPING))
              asm.jsr(asm.abs("rt_sfx_finish"))
              asm.ldy(at.call(STATE))
              asm.label("rt_sfx_frame_not_cut")
              asm.lda(state.call(ASKED_NOW))
              asm.beq("rt_sfx_frame_not_asked")
              if timed
                asm.lda(0) # started: the tick's pass after this one moves it on, from its first frame
                asm.sta(state.call(ASKED_NOW))
              end
              asm.lda(1)
              asm.sta(state.call(RUNNING))
              asm.lda(0)
              asm.sta(state.call(FRAME))
              SNES::Music::PARTS.times { |p| asm.sta(state.call(CURSORS + (p * 2))) }
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_START_LOG))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.bra("rt_sfx_frame_sounding")
              asm.label("rt_sfx_frame_not_asked")
              if timed # a pass that starts what was asked for plays nothing else
                asm.lda(asm.abs(memory[Music::EFFECTS_STARTING]))
                asm.beq("rt_sfx_frame_ticked")
                asm.rts
                asm.label("rt_sfx_frame_ticked")
              end
              asm.lda(state.call(RUNNING))
              asm.beq("rt_sfx_frame_sounding")
              asm.ldx(at.call(RECORD))
              asm.lda(state.call(FRAME))
              asm.cmp(asm.long_x("music_data", m::EFFECT_LENGTH))
              asm.bcc("rt_sfx_frame_sounding")
              asm.jsr(asm.abs("rt_sfx_finish"))
              asm.label("rt_sfx_frame_sounding")
              asm.ldy(at.call(STATE))
              asm.lda(state.call(RUNNING))
              asm.bne("rt_sfx_frame_parts")
              asm.rts
              asm.label("rt_sfx_frame_parts")
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_PART_COUNT))
              asm.sta(at.call(PARTS))
              asm.stz(at.call(PART))
              asm.label("rt_sfx_frame_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS))
              asm.branch_long(:bcs, "rt_sfx_frame_done")
              asm.jsr(asm.abs("rt_sfx_entry"))
              asm.lda(at.call(PART)) # its next note
              asm.asl
              asm.clc
              asm.adc(at.call(STATE))
              asm.tay
              asm.lda(asm.abs_y(memory[STATES], CURSORS))
              asm.cmp(asm.long_x("music_data", m::NOTE_COUNT))
              asm.branch_long(:bcs, "rt_sfx_frame_next")
              Music.emit_times(asm, m::NOTE_BYTES)
              asm.clc
              asm.adc(asm.long_x("music_data", m::NOTES_AT))
              asm.sta(at.call(NOTE))
              asm.tax
              asm.lda(asm.long_x("music_data", m::NOTE_FRAME))
              asm.ldy(at.call(STATE))
              asm.cmp(state.call(FRAME))
              asm.branch_long(:bne, "rt_sfx_frame_next")
              asm.lda(at.call(PART))
              asm.asl
              asm.clc
              asm.adc(at.call(STATE))
              asm.tax
              asm.inc(asm.abs_x(memory[STATES], CURSORS))
              if recorded # a part that plays a recording: its note in Recordings' places
                asm.ldx(at.call(ENTRY))
                asm.lda(asm.long_x("music_data", m::CHANNEL))
                asm.cmp(m::RECORDED_CHANNEL)
                asm.bcc("rt_sfx_frame_console")
                asm.jsr(asm.abs("rt_sfx_recorded_note"))
                asm.brl("rt_sfx_frame_next")
                asm.label("rt_sfx_frame_console")
              end
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_RANK))
              emit_claim_call(asm, memory, entry: ENTRY, note: NOTE)
              asm.branch_long(:beq, "rt_sfx_frame_next")
              if level_at # the tune's note there is no longer held for a new level to reach
                asm.lda(at.call(CLAIM_CHANNEL))
                asm.jsr(asm.abs("rt_music_unhold"))
              end
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_TAIL))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              # An effect's note changes as it plays as a tune's does, by the same steps, which read
              # the note from the tune's places (Reference::Player#set_voice).
              asm.lda(at.call(ENTRY))
              asm.sta(at.call(Music::ENTRY))
              asm.lda(at.call(NOTE))
              asm.sta(at.call(Music::NOTE))
              if Music.notes_apart?(memory) && Music.changes_notes?(memory) # where those steps read a note
                asm.tax
                asm.jsr(asm.abs("rt_music_note_from_table"))
              end
              Music.emit_note_changes(asm, memory)
              asm.label("rt_sfx_frame_next")
              asm.inc(at.call(PART))
              asm.brl("rt_sfx_frame_part")
              asm.label("rt_sfx_frame_done")
              asm.ldy(at.call(STATE))
              asm.lda(state.call(FRAME))
              asm.inc
              asm.sta(state.call(FRAME))
              asm.rts

              # rt_sfx_entry: ENTRY and X = where part PART of the effect selected is.
              asm.label("rt_sfx_entry")
              asm.lda(at.call(PART))
              Music.emit_times(asm, m::PART_BYTES)
              asm.clc
              asm.adc(at.call(RECORD))
              asm.clc
              asm.adc(m::EFFECT_RECORD_BYTES)
              asm.sta(at.call(ENTRY))
              asm.tax
              asm.rts
            end

            # rt_sfx_finish: the effect selected over (Reference::Player#finish_effect): not sounding,
            # and every voice it still holds free and quiet, in the order the voices were first held,
            # each through its part's group for letting the voice go; then, with +recorded+, each part
            # that plays a recording gives back the place it still sounds a note in.
            def emit_finish(asm, at, memory, recorded)
              m = SNES::Music
              asm.label("rt_sfx_finish")
              asm.ldy(at.call(STATE))
              asm.lda(0)
              asm.sta(asm.abs_y(memory[STATES], RUNNING))
              asm.inc(at.call(LIVE_CHANGED))
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_RANK))
              asm.sta(at.call(RELEASE_RANK))
              asm.stz(at.call(RELEASE_WALK))
              asm.label("rt_sfx_finish_next")
              asm.lda(at.call(RELEASE_WALK))
              asm.cmp(at.call(HOLDER_END))
              asm.bcs("rt_sfx_finish_done")
              asm.tax
              asm.lda(asm.abs_x(memory[HOLDER_ORDER]))
              asm.sta(at.call(RELEASE_CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HOLDERS]))
              asm.cmp(at.call(RELEASE_RANK))
              asm.bne("rt_sfx_finish_walk")
              asm.lda(0)
              asm.sta(asm.abs_y(memory[HOLDERS]))
              Music.emit_voice_stops_changing(asm, memory, at.call(RELEASE_CHANNEL))
              # Its part on that voice, whose group lets the voice go.
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_PART_COUNT))
              asm.sta(at.call(PARTS))
              asm.stz(at.call(PART))
              asm.label("rt_sfx_finish_find")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS))
              asm.bcs("rt_sfx_finish_walk")
              asm.jsr(asm.abs("rt_sfx_entry"))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(at.call(RELEASE_CHANNEL))
              asm.beq("rt_sfx_finish_found")
              asm.inc(at.call(PART))
              asm.bra("rt_sfx_finish_find")
              asm.label("rt_sfx_finish_found")
              asm.lda(asm.long_x("music_data", m::EFFECT_RELEASE))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.label("rt_sfx_finish_walk")
              asm.inc(at.call(RELEASE_WALK))
              asm.inc(at.call(RELEASE_WALK))
              asm.bra("rt_sfx_finish_next")
              asm.label("rt_sfx_finish_done")
              asm.jmp(asm.abs("rt_sfx_release_recorded")) if recorded
              asm.rts
            end

            # rt_sfx_recorded_note: the note at NOTE of the selected effect's part that plays a
            # recording, A its channel (SNES::Music::RECORDED_CHANNEL on), in a place the effect owns
            # (Recordings::EFFECT_OWNER): a note takes a place at the effect's rank and logs itself if
            # it found one; a note that sounds nothing gives the part's place back, and logs itself
            # only if the part had one (Reference::Player#play_effect_frame).
            #
            # rt_sfx_release_recorded: each of the selected effect's parts that plays a recording gives
            # back the place it still sounds a note in, logging its end through its release group if
            # it had one (Reference::Player#finish_effect).
            #
            # rt_sfx_owner: R1 = the owner number of the effect's part on channel A.
            def emit_recorded_parts(asm, at, memory)
              m = SNES::Music
              asm.label("rt_sfx_recorded_note")
              asm.jsr(asm.abs("rt_sfx_owner"))
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_RECORDING))
              asm.bne("rt_sfx_recorded_note_plays")
              asm.lda(asm.direct(Sound::R1))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_recordings_note_release"))
              asm.bra("rt_sfx_recorded_note_heard")
              asm.label("rt_sfx_recorded_note_plays")
              if memory.reserved?(Recordings::GLIDES)
                asm.bpl("rt_sfx_recorded_note_strikes")
                asm.and_a(m::GLIDES - 1)
                asm.dec
                asm.sta(asm.direct(Sound::R0))
                asm.jsl(asm.long("rt_recordings_glide"))
                asm.brl("rt_sfx_recorded_note_heard")
                asm.label("rt_sfx_recorded_note_strikes")
              end
              asm.dec
              asm.sta(asm.direct(Sound::R0))
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_RANK))
              asm.inc # above the game's own sounds, at nought
              asm.sta(asm.direct(Sound::R2))
              asm.jsl(asm.long("rt_recordings_note"))
              asm.label("rt_sfx_recorded_note_heard")
              asm.cmp(0)
              asm.beq("rt_sfx_recorded_note_done")
              asm.ldx(at.call(NOTE))
              asm.lda(asm.long_x("music_data", m::NOTE_HEAD))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.label("rt_sfx_recorded_note_done")
              asm.rts

              asm.label("rt_sfx_release_recorded")
              asm.ldx(at.call(RECORD))
              asm.lda(asm.long_x("music_data", m::EFFECT_PART_COUNT))
              asm.sta(at.call(PARTS))
              asm.stz(at.call(PART))
              asm.label("rt_sfx_release_recorded_part")
              asm.lda(at.call(PART))
              asm.cmp(at.call(PARTS))
              asm.bcs("rt_sfx_release_recorded_done")
              asm.jsr(asm.abs("rt_sfx_entry"))
              asm.lda(asm.long_x("music_data", m::CHANNEL))
              asm.cmp(m::RECORDED_CHANNEL)
              asm.bcc("rt_sfx_release_recorded_next") # a voice of the console's own, let go above
              asm.jsr(asm.abs("rt_sfx_owner"))
              asm.lda(asm.direct(Sound::R1))
              asm.sta(asm.direct(Sound::R0))
              asm.jsl(asm.long("rt_recordings_note_release"))
              asm.cmp(0)
              asm.beq("rt_sfx_release_recorded_next")
              asm.ldx(at.call(ENTRY))
              asm.lda(asm.long_x("music_data", m::EFFECT_RELEASE))
              asm.tax
              asm.jsr(asm.abs("rt_sound_group"))
              asm.label("rt_sfx_release_recorded_next")
              asm.inc(at.call(PART))
              asm.bra("rt_sfx_release_recorded_part")
              asm.label("rt_sfx_release_recorded_done")
              asm.rts

              asm.label("rt_sfx_owner")
              asm.sec
              asm.sbc(m::RECORDED_CHANNEL - 1) # the part's place among the effect's recorded parts, one up
              asm.sta(asm.direct(Sound::R1))
              asm.lda(at.call(EFFECT))
              asm.inc
              asm.xba # the effect's number, one up, in the high byte
              asm.ora(asm.direct(Sound::R1))
              asm.sta(asm.direct(Sound::R1))
              asm.rts
            end

            # rt_sfx_claim: may a note of rank CLAIM_RANK sound on CLAIM_CHANNEL? Yes (A = 1) when
            # nobody holding it outranks it, and then it holds the voice while it sounds
            # (CLAIM_SOUNDS), where a rest lets it go; nought otherwise
            # (Reference::Player#claim_channel).
            def emit_claim_routine(asm, at, memory)
              asm.label("rt_sfx_claim")
              asm.lda(at.call(CLAIM_CHANNEL))
              asm.dec
              asm.asl
              asm.tay
              asm.lda(asm.abs_y(memory[HOLDERS]))
              asm.cmp(at.call(CLAIM_RANK))
              asm.beq("rt_sfx_claim_taken")
              asm.bcs("rt_sfx_claim_refused")
              asm.label("rt_sfx_claim_taken")
              asm.lda(at.call(CLAIM_SOUNDS))
              asm.beq("rt_sfx_claim_hold")
              asm.lda(at.call(CLAIM_RANK))
              asm.label("rt_sfx_claim_hold")
              asm.sta(asm.abs_y(memory[HOLDERS]))
              asm.lda(asm.abs_y(memory[HOLDER_SEEN]))
              asm.bne("rt_sfx_claim_known")
              asm.lda(1)
              asm.sta(asm.abs_y(memory[HOLDER_SEEN]))
              asm.ldx(at.call(HOLDER_END))
              asm.lda(at.call(CLAIM_CHANNEL))
              asm.sta(asm.abs_x(memory[HOLDER_ORDER]))
              asm.inx
              asm.inx
              asm.stx(at.call(HOLDER_END))
              asm.label("rt_sfx_claim_known")
              asm.lda(1)
              asm.rts
              asm.label("rt_sfx_claim_refused")
              asm.lda(0)
              asm.rts
            end

            # rt_sfx_select: the effect numbered A selected — effect, record and X where its record is,
            # STATE and Y where its state is.
            def emit_select(asm, at, memory)
              asm.label("rt_sfx_select")
              asm.sta(at.call(EFFECT))
              Music.emit_times(asm, STATE_BYTES)
              asm.sta(at.call(STATE))
              asm.lda(at.call(EFFECT))
              asm.asl
              asm.clc
              asm.adc(asm.long("music_data", SNES::Music::EFFECTS_AT))
              asm.tax
              asm.lda(asm.long_x("music_data"))
              asm.sta(at.call(RECORD))
              asm.tax
              asm.ldy(at.call(STATE))
              asm.rts
            end
          end
        end
      end
    end
  end
end
