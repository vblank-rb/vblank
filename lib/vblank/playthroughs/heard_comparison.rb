# frozen_string_literal: true

module VBlank
  module Playthroughs
    # How far apart two cartridges' heard sound may be and still be alike. A game gives all three,
    # each with its reason beside it in the game's test: none has a value a comparison assumes.
    #
    #   first_heard_frames_apart  how many frames apart the two may first be heard
    #   level_share_apart         how far apart their levels may be, as a share of the louder one's,
    #                             from 0 to 1 (HeardSound#level)
    #   ending_frames_apart       how many frames apart they may be last heard, and how many frames
    #                             apart their last sounds may take to fall silent (HeardSound#fall_frames)
    #
    # and one the game may give: +level_stretch_frames+ holds the level a stretch of that many frames
    # at a time (60 is a second on most consoles), so a song loud where the original is quiet and quiet
    # where it is loud is found, which one average over the whole song hides. Left out, the level is
    # one average over the frames heard.
    HeardTolerances = Data.define(:first_heard_frames_apart, :level_share_apart, :ending_frames_apart,
                                  :level_stretch_frames) do
      def initialize(first_heard_frames_apart:, level_share_apart:, ending_frames_apart:, level_stretch_frames: nil)
        HeardComparison.refuse_frames_not_count!(:first_heard_frames_apart, first_heard_frames_apart)
        HeardComparison.refuse_frames_not_count!(:ending_frames_apart, ending_frames_apart)
        unless level_share_apart.is_a?(Numeric) && level_share_apart.between?(0, 1)
          raise ArgumentError, "`level_share_apart:` was #{level_share_apart.inspect}. It is a share of the louder " \
                               "cartridge's level, so it must be a number from 0 to 1. `level_share_apart: 0.1` is a tenth."
        end
        unless level_stretch_frames.nil? || (level_stretch_frames.is_a?(Integer) && level_stretch_frames.positive?)
          raise ArgumentError, "`level_stretch_frames:` was #{level_stretch_frames.inspect}. It is how many frames the " \
                               "level is held over at a time, so it must be a whole number, 1 or more. " \
                               "`level_stretch_frames: 60` is a second."
        end
        super
      end
    end

    # Where two cartridges' heard sound differs by more than the game allows, for one measure.
    #
    # +what+ is which measure was out: +:never_heard+ (one cartridge or both made no sound),
    # +:first_heard+, +:level+, +:last_heard+ or +:fall+. +frame+ is the first frame the two differ
    # on for that reason, counted from 1 (nil where neither was heard), and +loudest+ the loudest
    # sample each put out on it, the first cartridge's and then the second's. +measured+ is the
    # measure itself on each: the frame each was first or last heard on, each one's level, or the
    # frames each one's last sound took to fall silent. For a level held a stretch at a time
    # (HeardTolerances), +frames+ is the first stretch out, +measured+ each one's level over it, and
    # +stretches_over+ how many stretches are out; both are nil otherwise. +speaker+ is :left or
    # :right for a difference found on that speaker alone, where the two speakers mixed are alike for
    # that measure (a sound on the wrong speaker); nil for one found in the mixed sound.
    HeardDifference = Data.define(:what, :frame, :loudest, :measured, :frames, :stretches_over, :speaker) do
      def initialize(what:, frame:, loudest:, measured:, frames: nil, stretches_over: nil, speaker: nil) = super
    end

    # Two cartridges' heard sound on the same presses, in the same emulator: a port's cartridge beside
    # the original it is made from. The same mixer makes both sounds, so the two can be held close:
    # heard from the same frame, at the same level, and falling silent over the same time.
    #
    #   compared = HeardComparison.play(tape, ours, "original.sfc", heard_above: 0,
    #                                   first_heard_frames_apart: 0, level_share_apart: 0.1,
    #                                   ending_frames_apart: 6)
    #   compared.alike?            # => false
    #   compared.difference.what   # => :level
    #   compared.first.level       # each side is a HeardSound
    #
    # What is compared, in this order: whether each is heard at all; the frame each is first heard on;
    # each one's level over the frames it is heard, or a stretch of them at a time; the frame each is
    # last heard on; and how many frames each one's last sound takes to fall silent. Every measure out
    # is a HeardDifference in +differences+, so one run shows them all; #difference is the first. (One
    # never heard is the only difference: the rest measure a sound.) It is the loudest sample a frame
    # and nothing finer: a wrong note at the right loudness passes. Play the tape past the end of the
    # sound, or the last frame heard is the tape's last.
    #
    # +recordings+ is what each cartridge put out, as Diagnostics::SoundRecordings, for #write_wav; nil
    # for a comparison of HeardSounds made elsewhere (#between).
    #
    # Each speaker. The measures are taken of the two speakers mixed, and again of each speaker
    # alone (+speakers+, :left and :right to the two HeardSounds on it): a measure out on one speaker
    # and not in the mix is a difference of its own, naming the speaker, so a sound on the wrong
    # speaker fails.
    #
    # Each voice. Where the two are not alike and the console's emulator can play one voice alone
    # (the Advance's and the Color's four, the Genesis's six FM voices and four square and noise
    # voices, the Super Nintendo's eight), the tape is played again on both once for each voice,
    # that voice alone, and compared the same way: +voices+ is each voice's name to its own
    # HeardComparison, so a failure names the voice that differs. It only explains: whether the two
    # are alike is the mixed sound's answer. Empty where no voice can be played alone; nil where the
    # two are alike or it was not asked for.
    #
    # In a test this is Testing::HeardAlike#assert_heard_alike.
    #
    # Chosen voices. +hearing+ is the voices heard on each side where the game chose them (the first
    # cartridge's list, then the second's), and nil where every voice was heard.
    #
    # +frames_stepped+ is how many frames each cartridge's emulator stepped to make its sound, the
    # first's and then the second's (Diagnostics::Verifier#frames_played): every frame of the tape
    # from power-on, or the frames after the start where each was put there from a snapshot (and the
    # few before it an emulator plays for its sound to settle, Console::Kit#frames_sound_settles_after_load).
    # Nil for a comparison of HeardSounds made elsewhere (#between).
    HeardComparison = Data.define(:first, :second, :differences, :recordings, :speakers, :voices, :hearing, :frames_stepped) do
      def initialize(first:, second:, differences:, recordings: nil, speakers: nil, voices: nil, hearing: nil,
                     frames_stepped: nil) = super
    end

    class HeardComparison
      SPEAKERS = %i[left right].freeze
      # What a side of +hearing+ names for a cartridge's sound effects alone, on whichever voices they are.
      SOUND_EFFECTS = :sound_effects

      # Play +presses+ (a Tape, or a Playthrough, whose script is played on +first+ and the presses
      # it made on +second+) on both cartridges from power-on, and compare what each put out.
      # +heard_above+ is the loudest sample a silent frame may have (HeardSound), and the rest are
      # HeardTolerances'. +lead_ins+ is a playthrough for each cartridge to play first, not counted
      # (Playthrough#play), for two cartridges that reach the first screen by different roads.
      # +each_speaker+ false compares the speakers mixed alone, for two that are meant to place
      # their sound differently; +each_voice+ false plays no voice alone after a difference.
      #
      # +hearing+ chooses the voices heard on each side, the first cartridge's list and then the
      # second's, by the names Diagnostics::Verifier#channels gives: `hearing: [[:square1], [:square2]]`.
      # Only those are heard from power-on, so one sound is held to the original's while the rest
      # under it differs, on whichever voice each cartridge plays it. The two lists need not name the
      # same voices, or as many. Every measure is taken of what is heard; no voice is played alone
      # afterwards, since the game has chosen them.
      #
      # A side can be +:sound_effects+ in place of its list: that cartridge's sound effects alone,
      # on whichever voices its sound player put their notes, frame by frame
      # (`hearing: [:sound_effects, [:voice0]]`). It is for a build whose player moves an effect's
      # notes between voices the tune also plays on, so no list of voices hears the effect without
      # some of the tune. Each frame is heard on the voices the effects hold at its end
      # (Verifier#sound_effect_voices), read off a second console playing a frame ahead, and no
      # other (VoiceReplay#effects_side says why). The sound chip runs a little behind the
      # processor, so a frame a voice changes hands on starts with a few samples of whoever had it
      # before, inside that one frame: an effect alone is heard from the frame it starts on to the
      # frame it ends on. It needs a cartridge built here, whose build says where its player keeps
      # who holds each voice, for a console whose player moves an effect's notes between voices:
      # the Super Nintendo's. Heard so, it plays the tape twice.
      #
      # ### Starting after a frame
      #
      # +starting_after+ is a frame of the tape, by its number or by the name of one of its moments,
      # that each cartridge is played to without being heard: the sound is compared from the frame
      # after. With +snapshots+ (a SnapshotCache) each is put on that frame from a snapshot of its
      # console, made the first time and loaded every time after, the same snapshot a picture
      # comparison or a probe started there loads (Comparison, Probe). So a comparison of a moment
      # deep in a tape costs the frames it hears, for each voice played alone too. Without
      # +snapshots+ each is played there from power-on.
      #
      # On the Advance and the Color the sound after a snapshot is put back is the console's own,
      # sample for sample. bsnes's and Genesis Plus GX's output comes back only after a frame or a
      # few, so on the Super Nintendo and the Genesis the snapshot is of that many frames before the
      # start, and they are played unheard (Console::Kit#frames_sound_settles_after_load); from
      # there each frame's loudest sample is within a few thousandths of the console's.
      #
      # Every measure (first heard, level, last heard, fall) is of the frames after the start alone,
      # and frames are still counted from power-on. So a sound that started before the start is heard
      # from the frame after it: a test of a sound already playing at the start says so in its
      # tolerances or starts earlier. A start takes no lead-ins: the frames before it are not heard,
      # so a lead-in has nothing to keep out of the count.
      #
      # A voice played alone (+hearing+, each voice's replay, :sound_effects) is put on the start
      # from a snapshot of its own, of a console that heard those voices alone from power-on: what
      # an emulator has already mixed when the snapshot is taken is of the voices it heard, and from
      # a snapshot of every voice the first frame after the start would carry the others. So each
      # voice replayed costs the frames before the start once, the first time. The voices are chosen
      # before the snapshot is put back, and kept as it loads (Diagnostics::Verifier#load_state).
      #
      # The :sound_effects side opens two consoles on the start, the one heard from a snapshot that
      # heard nothing and the one a frame ahead from the mixed sound's, and the one ahead plays each
      # frame first from there as it does from power-on. An effect sounding as the start comes is
      # heard from the frame after it, as any sound is.
      def self.play(presses, first, second, heard_above:, lead_ins: [nil, nil], each_speaker: true, each_voice: true,
                    hearing: nil, starting_after: nil, snapshots: nil, **tolerances)
        tolerances = HeardTolerances.new(**tolerances)
        refuse_frames_not_count!(:heard_above, heard_above)
        refuse_lead_ins_not_pair!(lead_ins)
        refuse_unusable_presses!(presses, lead_ins)
        refuse_hearing_not_pair!(hearing)
        refuse_unusable_start!(starting_after, snapshots, lead_ins)
        replays = [first, second].zip(lead_ins).map do |cartridge, lead_in|
          VoiceReplay.new(cartridge, lead_in, heard_above, snapshots: snapshots)
        end
        replays.zip(hearing) { |replay, voices| replay.refuse_unknown_voices!(voices) } if hearing
        from_power_on = starting_after.nil? && !(hearing && presses.is_a?(Tape))
        played = presses_led_in(presses, lead_ins[0]).play(first, lead_in: lead_ins[0]) if from_power_on || presses.is_a?(Playthrough)
        tape = presses.is_a?(Tape) ? presses : played.tape
        start = start_frame_on(tape, starting_after)
        sides = if hearing || !from_power_on
                  replays.zip(hearing || [nil, nil]).map { |replay, voices| replay.side(tape, voices, start) }
                else
                  [Side.of(played, heard_above), Side.of(presses_led_in(tape, lead_ins[1]).play(second, lead_in: lead_ins[1]), heard_above)]
                end
        compared = between(*sides.map(&:mixed), tolerances, recordings: sides.map(&:recording),
                                                            speakers: each_speaker ? Side.speakers(sides) : nil)
                   .with(hearing: hearing, frames_stepped: sides.map(&:frames_stepped))
        return compared if compared.alike? || !each_voice || hearing

        compared.with(voices: replays.first.voices.to_h do |voice|
          alone = replays.map { |replay| replay.side(tape, [voice], start) }
          [voice, between(*alone.map(&:mixed), tolerances).with(frames_stepped: alone.map(&:frames_stepped))]
        end)
      end

      # What one cartridge put out over the tape: the two speakers mixed, each alone, the sound, and
      # how many frames its emulator stepped to make it (Verifier#frames_played).
      Side = Data.define(:mixed, :left, :right, :recording, :frames_stepped) do
        # The Side of +played+ (a played playthrough or tape: its +game+ and its +frames+), heard from
        # the frame after +starts_after+.
        def self.of(played, heard_above, starts_after = 0)
          by_speaker = SPEAKERS.to_h do |speaker|
            [speaker, HeardSound.of(played, heard_above: heard_above, speaker: speaker, starts_after: starts_after)]
          end
          new(mixed: HeardSound.of(played, heard_above: heard_above, starts_after: starts_after), **by_speaker,
              recording: Diagnostics::SoundRecording.heard_in(played.game, frames: played.frames - starts_after),
              frames_stepped: played.game.frames_played)
        end

        # Each speaker, :left and :right, to the two sides' HeardSounds on it.
        def self.speakers(sides) = { left: sides.map(&:left), right: sides.map(&:right) }
      end
      private_constant :Side

      # The comparison of two HeardSounds, +first+ and +second+, by +tolerances+ (a HeardTolerances), and
      # of each speaker's where +speakers+ gives them (:left and :right to a pair of HeardSounds).
      def self.between(first, second, tolerances, recordings: nil, speakers: nil)
        mixed = Differences.new(first, second, tolerances).all
        on_one = (speakers || {}).flat_map do |speaker, pair|
          Differences.new(*pair, tolerances).all.reject { |found| mixed.any? { |out| out.what == found.what } }
                     .map { |found| found.with(speaker: speaker) }
        end
        new(first: first, second: second, differences: mixed + on_one, recordings: recordings, speakers: speakers)
      end

      def alike? = differences.empty?

      # The first measure out, or nil where the two are alike.
      def difference = differences.first

      # Both cartridges' sound written to +path+ as one WAV file for a person to hear (SoundRecording.write_pair):
      # +layout+ :in_turn plays the first and then the second, :side_by_side the first on the left speaker
      # and the second on the right. Answers +path+.
      def write_wav(path, layout:)
        raise ArgumentError, "This comparison was made from the loudest samples alone, with no sound to write." unless recordings

        Diagnostics::SoundRecording.write_pair(path, *recordings, layout: layout)
      end

      # A tape says whether it was recorded after a lead-in, and is refused played another way. Each
      # cartridge here has a lead-in of its own or none, so each is handed the tape saying its own.
      def self.presses_led_in(presses, lead_in)
        presses.is_a?(Tape) ? presses.started_from(save: nil, led_in: !lead_in.nil?) : presses
      end

      def self.refuse_frames_not_count!(name, given)
        return if given.is_a?(Integer) && !given.negative?

        raise ArgumentError, "`#{name}:` was #{given.inspect}. It must be a whole number, 0 or more."
      end

      def self.refuse_lead_ins_not_pair!(lead_ins)
        return if lead_ins.is_a?(Array) && lead_ins.size == 2

        raise ArgumentError, "`lead_ins:` was #{lead_ins.inspect}. It must be a list of two, the first cartridge's " \
                             "lead-in and then the second's, each a playthrough or nil: `lead_ins: [nil, past_the_logos]`."
      end

      def self.refuse_unusable_presses!(presses, lead_ins)
        unless presses.is_a?(Tape) || presses.is_a?(Playthrough)
          raise ArgumentError, "The presses were #{presses.inspect}. Give a tape (`played.tape`, `Tape.read`) or a " \
                               "playthrough (`VBlank.playthrough`)."
        end
        return unless presses.is_a?(Tape)

        presses.refuse_seed_frame_by_frame!("a comparison of sound")
        if presses.in_passes
          raise ArgumentError, "This tape counts passes, and the sound is compared frame by frame. To fix this, give a " \
                               "tape of frames: `tape.in_frames_on(cartridge)`."
        end
        if presses.recorded_from_save?
          raise ArgumentError, "This tape was recorded from a save, and the sound is compared from power-on. To fix " \
                               "this, give a tape recorded from power-on."
        end
        return unless presses.recorded_after_lead_in? && lead_ins.compact.empty?

        raise ArgumentError, "This tape was recorded after a lead-in, which is not on the tape. Give the lead-in of " \
                             "each cartridge: `lead_ins: [first_lead_in, second_lead_in]`."
      end
      private_class_method :presses_led_in, :refuse_lead_ins_not_pair!, :refuse_unusable_presses!

      # +hearing+ is nil, or each cartridge's voices as a pair, the first's and then the second's: each
      # a list of voices or SOUND_EFFECTS.
      def self.refuse_hearing_not_pair!(hearing)
        return if hearing.nil?
        return if hearing.is_a?(Array) && hearing.size == 2 &&
                  hearing.all? { |voices| voices == SOUND_EFFECTS || (voices.is_a?(Array) && !voices.empty?) }

        raise ArgumentError, "`hearing:` was #{hearing.inspect}. It must be a list of two, the first cartridge's voices " \
                             "and then the second's. Each is a list of voices or :sound_effects: " \
                             "`hearing: [[:square1], [:square2]]` or `hearing: [:sound_effects, [:voice0]]`."
      end
      private_class_method :refuse_hearing_not_pair!

      # What a start after a frame cannot be given: snapshots with no start, and lead-ins, whose
      # presses are not known until they have played, so nothing can say which snapshot they reach.
      def self.refuse_unusable_start!(starting_after, snapshots, lead_ins)
        if snapshots && !snapshots.is_a?(SnapshotCache)
          raise ArgumentError, "`snapshots:` was #{snapshots.inspect}. It must be a SnapshotCache: " \
                               "`snapshots: VBlank::Playthroughs::SnapshotCache.new(\".cache/snapshots\")`."
        end
        if starting_after.nil?
          return unless snapshots

          raise ArgumentError, "The comparison was given `snapshots:` and no `starting_after:`. A snapshot is used only " \
                               "to start after a frame. Give `starting_after:` the frame, or remove `snapshots:`."
        end
        unless starting_after.is_a?(Symbol) || (starting_after.is_a?(Integer) && starting_after >= 1)
          raise ArgumentError, "`starting_after:` was #{starting_after.inspect}. It must be a frame of the tape, a whole " \
                               "number 1 or more, or the name of one of its moments."
        end
        return if lead_ins.compact.empty?

        raise ArgumentError, "The comparison was given `starting_after:` and `lead_ins:`. The frames before the start " \
                             "are not heard, so a lead-in is not needed. Remove `lead_ins:`, or remove `starting_after:`."
      end

      # The frame of +tape+ the sound is heard after, 0 for power-on: a number, or a moment's frame.
      def self.start_frame_on(tape, starting_after)
        return 0 if starting_after.nil?

        frame = if starting_after.is_a?(Symbol)
                  tape.moments.fetch(starting_after) do
                    raise ArgumentError, "`starting_after:` names the moment #{starting_after.inspect}, and the tape has " \
                                         "no moment of that name. Its moments are #{tape.moments.keys.map(&:inspect).join(', ')}."
                  end
                else
                  starting_after
                end
        return frame if frame < tape.frames

        raise ArgumentError, "`starting_after:` is frame #{frame}, and the tape plays #{tape.frames} frames. Nothing is " \
                             "left to hear after it. Give a frame before the tape's last."
      end
      private_class_method :refuse_unusable_start!, :start_frame_on

      # One cartridge's tape played again with only some voices heard: switched on, told which voices
      # to hear (Verifier#hearing) before its first frame, led in, and pressed through the tape a
      # stretch of frames at a time, as a playthrough presses it.
      class VoiceReplay
        # A replay's reader and the frames it played: what Side.of reads of a playing.
        Played = Data.define(:game, :frames)

        def initialize(cartridge, lead_in, heard_above, snapshots: nil)
          @cartridge = cartridge
          @lead_in = lead_in
          @heard_above = heard_above
          @snapshots = snapshots
        end

        # The voices this cartridge's emulator can play alone: none on a console whose emulator mixes
        # them all.
        def voices
          reader = Playthrough.power_on(@cartridge)
          reader.respond_to?(:channels) ? reader.channels : []
        ensure
          reader&.close
        end

        # +voices+ refused before anything is played where this cartridge's console has no voice by one
        # of those names, or none can be heard alone.
        def refuse_unknown_voices!(voices)
          known = self.voices
          if known.empty?
            raise ArgumentError, "`hearing:` names voices, and this cartridge's emulator cannot play a voice alone. " \
                                 "To fix this, remove `hearing:`."
          end
          return refuse_unfollowable_effects! if voices == SOUND_EFFECTS

          unknown = voices - known
          return if unknown.empty?

          raise ArgumentError, "`hearing:` names #{unknown.map(&:inspect).join(', ')}, and this cartridge has no voice " \
                               "#{unknown.join(', ')}. Its voices are #{known.map(&:inspect).join(', ')}."
        end

        # :sound_effects refused where nothing can say which voices the effects hold on each frame: a
        # console whose player keeps each part of an effect on one voice, which a list can name, or a
        # cartridge not built here, whose build record would say where its player keeps that.
        def refuse_unfollowable_effects!
          reader = Playthrough.power_on(@cartridge)
          unless reader.respond_to?(:sound_effect_voices)
            raise ArgumentError, "`hearing:` asks for :sound_effects, and on this console each part of a sound effect " \
                                 "plays on one voice. To fix this, name the voices of the effect: " \
                                 "`hearing: [[:square2], [:square2]]`."
          end
          return if Playthrough.cartridge_from(@cartridge).built

          raise ArgumentError, "`hearing:` asks for :sound_effects of a cartridge that was not built here. Nothing " \
                               "says which voices its sound player gives its effects. To fix this, name the voices " \
                               "of that cartridge: `hearing: [:sound_effects, [:voice0]]`."
        ensure
          reader&.close
        end

        # The Side of +voices+ alone over +tape+'s frames after +start+, or of the sound effects alone
        # (SOUND_EFFECTS), or of every voice where +voices+ is nil.
        def side(tape, voices, start = 0)
          return effects_side(tape, start) if voices == SOUND_EFFECTS

          reader = opened(tape, start, voices)
          tape.presses_within((start + 1)..tape.frames).each do |stretch|
            reader.step(stretch.frames.size, keys: IR::Buttons.mask(stretch.buttons))
          end
          Side.of(Played.new(game: reader, frames: tape.frames), @heard_above, start)
        ensure
          reader&.close
        end

        # A console of this cartridge hearing +voices+ (every voice where nil), on frame +start+ of
        # +tape+: switched on and led in for 0, else put on that frame from a snapshot where there
        # are +snapshots+, or played there. The voices are chosen as it is switched on, before a
        # snapshot is put back: a Genesis's are chosen only before its first frame, and each reader
        # keeps its choice as a state loads (Verifier#load_state). The snapshot is of a console that
        # heard those voices alone from power-on (SnapshotCache#console_after's +hearing+).
        def opened(tape, start, voices)
          open = lambda do
            Playthrough.power_on(@cartridge).tap { |reader| reader.hearing(only: voices) if voices }
          end
          return open.call.tap { |reader| @lead_in&.play_as_lead_in(reader) } if start.zero?

          return open.call.tap { |reader| step_through(reader, tape, 1..start) } unless @snapshots

          # An emulator whose sound comes back only after a few frames is put back that many frames
          # before the start, and plays them unheard (Console::Kit#frames_sound_settles_after_load).
          refuse_snapshot_without_save_memory!
          snapshot_frame = [start - Console.for(cartridge.console).frames_sound_settles_after_load, 1].max
          presses = SnapshotCache.presses_up_to(tape, snapshot_frame)
          @snapshots.console_after(presses, cartridge, hearing: voices, &open)
                    .tap { |reader| step_through(reader, tape, (snapshot_frame + 1)..start) }
        end

        # +reader+ pressed through +frames+ of +tape+ (none where the range is empty).
        def step_through(reader, tape, frames)
          return if frames.none?

          tape.presses_within(frames).each { |stretch| reader.step(stretch.frames.size, keys: IR::Buttons.mask(stretch.buttons)) }
        end

        # The cartridge, read once from its path where it was given by one.
        def cartridge = @cartridge = Playthrough.cartridge_from(@cartridge)

        # A cartridge whose console's snapshot would leave out what it saved, refused
        # (Console::Kit#snapshot_leaves_out_save_memory?).
        def refuse_snapshot_without_save_memory!
          kit = Console.for(cartridge.console)
          return unless kit.snapshot_leaves_out_save_memory?(cartridge)

          raise ArgumentError, "A cartridge of the comparison keeps a save, and a snapshot of a #{kit.title} does not " \
                               "hold what it saved. To fix this, remove `snapshots:`, and the cartridge is played to the start."
        end

        # The Side of the sound effects alone over +tape+'s frames.
        #
        # ### Why a second console plays a frame ahead
        #
        # The sound player decides who holds each voice as a frame is played, and the chip sounds
        # that frame's notes before it ends. So which voices to hear on a frame is known only once
        # it has been played. A second console, +ahead+, plays each frame first, on the same
        # presses, and the console heard then plays it with the voices the effects held at its end.
        # Heard with the voices held at the end of the frame before, an effect's first frame would
        # be silent; and with those as well, the frame after each of its notes would carry the
        # tune's next note there, since a recording's place stays held for a frame after its last
        # sample. What is left is the few samples of a frame the chip plays before a change reaches
        # it, inside the frame either way.
        #
        # From a start both consoles are put on the start's frame: the one ahead plays each frame
        # first there as well, so neither needs a snapshot of the frame after.
        def effects_side(tape, start)
          heard = opened(tape, start, [])
          ahead = opened(tape, start, nil)
          tape.presses_within((start + 1)..tape.frames).each do |stretch|
            keys = IR::Buttons.mask(stretch.buttons)
            stretch.frames.size.times do
              heard.hearing(only: ahead.step(1, keys: keys).sound_effect_voices).step(1, keys: keys)
            end
          end
          Side.of(Played.new(game: heard, frames: tape.frames), @heard_above, start)
        ensure
          heard&.close
          ahead&.close
        end
      end
      private_constant :VoiceReplay

      # The checks, each answering a HeardDifference or nil, in the order they are made.
      class Differences
        def initialize(first, second, tolerances)
          @first = first
          @second = second
          @sides = [first, second]
          @tolerances = tolerances
        end

        # Every measure out, in the order they are checked.
        def all
          missing = never_heard
          return [missing] if missing

          [first_heard, level, last_heard, fall].compact
        end

        private

        def difference(what, frame, measured)
          HeardDifference.new(what: what, frame: frame, loudest: frame ? @sides.map { |side| side.loudest_on(frame) } : nil,
                              measured: measured)
        end

        def never_heard
          return if @sides.all?(&:heard?)

          difference(:never_heard, @sides.filter_map(&:first_heard).min, @sides.map(&:first_heard))
        end

        def first_heard
          frames = @sides.map(&:first_heard)
          difference(:first_heard, frames.min, frames) if apart(frames) > @tolerances.first_heard_frames_apart
        end

        # The frame named is the first on which the two frames' loudest samples are further apart than
        # the share, or the first frame either is heard on when no single frame is.
        def level
          return stretched_level if @tolerances.level_stretch_frames

          levels = @sides.map(&:level)
          return unless out_of_share?(levels)

          difference(:level, first_frame_out(heard_span) || heard_span.first, levels)
        end

        # The level a stretch of frames at a time, over the frames either is heard on: the first stretch
        # out, each one's level over it, and how many are out.
        def stretched_level
          stretches = heard_span.each_slice(@tolerances.level_stretch_frames).map { |frames| frames.first..frames.last }
          levels = stretches.to_h { |frames| [frames, @sides.map { |side| side.level_over(frames) }] }
          over = stretches.select { |frames| out_of_share?(levels[frames]) }
          return if over.empty?

          frames = over.first
          HeardDifference.new(what: :level, frame: first_frame_out(frames) || frames.first,
                              loudest: @sides.map { |side| side.loudest_on(first_frame_out(frames) || frames.first) },
                              measured: levels[frames], frames: frames, stretches_over: over.size)
        end

        def heard_span = @sides.map(&:first_heard).min..@sides.map(&:last_heard).max

        def out_of_share?(pair) = apart(pair) > @tolerances.level_share_apart * pair.max

        def first_frame_out(frames) = frames.find { |at| out_of_share?(@sides.map { |side| side.loudest_on(at) }) }

        # The frame named is the first on which one has fallen silent and the other is still heard.
        def last_heard
          frames = @sides.map(&:last_heard)
          difference(:last_heard, frames.min + 1, frames) if apart(frames) > @tolerances.ending_frames_apart
        end

        # The frame named is the first after the earlier of the two starts to fall away.
        def fall
          falls = @sides.map(&:fall_frames)
          difference(:fall, @sides.map(&:fall_starts).min + 1, falls) if apart(falls) > @tolerances.ending_frames_apart
        end

        def apart(pair) = (pair[0] - pair[1]).abs
      end
      private_constant :Differences
    end
  end
end
