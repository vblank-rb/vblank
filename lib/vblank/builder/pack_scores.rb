# frozen_string_literal: true

module VBlank
  class Builder
    # THE ORIGINAL'S SONGS AND SOUND EFFECTS AS NOTES, read from the data pack, and its instruments'
    # settings with them.
    #
    #   pack = data_pack from: ORIGINAL, version: "1.0" do |slots|
    #     slots.samples :horn,     count: 4096
    #     slots.numbers :tuning,   count: 9, width: :word, signed: false
    #     slots.numbers :shapes,   count: 36, width: :byte, signed: false
    #     slots.notes   :title_0,  count: 200
    #     slots.fill_from_copy { |copy, pack| ... }   # runs the original's sound driver into the notes
    #   end
    #   instrument :horn, pcm: pack[:horn], rate: pack[:tuning].number(0), envelope: pack[:shapes].envelope(0)
    #   melody = VBlank::Audio::Score::Part.new(plays: :horn, notes: pack[:title_0].notes(instruments: %i[horn bass]))
    #   music = songs :music, [VBlank::Audio::Score.new(parts: [melody], ticks_per_beat: 24, plays_once: true)]
    #
    # A part's notes are a slot of Original::PackNote records, VBlank's own, which the port's
    # unpacking routine writes as its original's sound driver would play them. Everything else about
    # a Score (its tempo, its loop, its parts' settings) is the game's, written in Ruby as for any
    # Score. An instrument's rate, the sample it holds from and its envelope can each be a number of a
    # slot (`rate: pack[:tuning].number(3)`), read where the game is built. An envelope kept as a
    # Super Nintendo's sound chip keeps it is three bytes of a slot (`pack[:adsr].snes_envelope(0)`).
    #
    # BUILT ALL-IN-ONE, the notes and the numbers are read here, and the song is the Score a port
    # would have written by hand, so every console and build plays it as any Score.
    #
    # WITH THE PACK LEFT OUT nothing here can be known. An instrument's rate, the sample it holds
    # from and its envelope of four bytes are then read as the game starts: the recording keeps
    # where each is in the start file (#recording_settings_in_start_file) and a stand-in for the
    # number. A part's notes are read then too: the part keeps where its records are and what
    # turns them into events (#song_reading_notes_at_start), and its Score must give its length:
    # a number of its own, or one of the pack with the most it can be (`longest:`), which is then
    # read as the game starts too, with the tick it comes round to. So is the wave a part plays
    # from a slot (`plays: pack[:waves].wave(0)`, #pack_wave_in_start_file). So is an envelope of
    # three bytes as a Super Nintendo's sound chip keeps it, as the nearest ordinary envelope.
    module PackScores
      private

      # +scores+ (a list or a Hash of Audio::Score, for `songs` or `sound_effects`) with each part
      # whose notes are a slot of the pack given the notes the slot holds. +verb+ names the line.
      def scores_with_pack_notes(scores, verb)
        read = ->(score) { score.is_a?(Audio::Score) ? score_with_pack_notes(score, verb) : score }
        scores.is_a?(Hash) ? scores.transform_values(&read) : Array(scores).map(&read)
      end

      def score_with_pack_notes(score, verb)
        return score unless score.parts.any? { |part| pack_notes?(part.notes) || part.plays.is_a?(DSL::PackWave) } || pack_timing?(score)
        return score_reading_notes_at_start(score, verb) if pack_left_out?

        parts = score.parts.map do |part|
          part = part.with(plays: pack_wave_steps(part.plays, verb)) if part.plays.is_a?(DSL::PackWave)
          pack_notes?(part.notes) ? part.with(notes: notes_read_from_pack(part, verb)) : part
        end
        score.with(parts: parts, length: pack_setting_value(score.length, "#{verb} reading a song's length", nil),
                   loop_from: pack_setting_value(score.loop_from, "#{verb} reading where a song comes round", nil))
      end

      def pack_notes?(notes)
        notes.is_a?(DSL::PackNotes) || (notes.is_a?(DSL::PackSlot) && Original::Slot::NOTE_SHAPES.include?(notes.shape))
      end

      # The 32 steps of the wave +wave+ (a DSL::PackWave) names, read here, as a part's `plays:`
      # takes a wave of its own.
      def pack_wave_steps(wave, verb)
        subject = "#{verb} reading a wave from slot :#{wave.slot.layout.name}"
        refuse_slot_from_elsewhere!(wave.slot, subject)
        DSL::PackWave.steps_of(pack_slot_values(wave.slot, :numbers, subject).slice(wave.first_byte, DSL::PackWave::BYTES))
      end

      # Where the wave +wave+ (a DSL::PackWave) names is in the start file, with the pack left out:
      # the part plays a stand-in until the file is read (IR::StartFile::Wave).
      def pack_wave_in_start_file(wave, verb)
        refuse_slot_from_elsewhere!(wave.slot, "#{verb} reading a wave from slot :#{wave.slot.layout.name}")
        IR::StartFile::Wave.new(at: @pack_slot_starts.fetch(wave.slot.layout.name) + wave.first_byte)
      end

      # Whether +score+ reads its length or the tick it comes round to from the pack.
      def pack_timing?(score) = [score.length, score.loop_from].any?(DSL::PackNumber)

      # WITH THE PACK LEFT OUT a part keeps its handle (a DSL::PackNotes) until the song is
      # recorded (#song_reading_notes_at_start), and the Score is held to what such a build needs:
      # its length, since where the last note ends is in the pack. A length read from the pack
      # comes with the most it can be (`longest:`). A part that plays a wave of the pack plays it
      # from where it is in the start file (#pack_wave_in_start_file), which needs no length.
      def score_reading_notes_at_start(score, verb)
        if score.parts.any? { |part| pack_notes?(part.notes) } || pack_timing?(score)
          refuse_pack_score_without_length!(score, verb)
          refuse_pack_timing_beside_written_parts!(score, verb)
          Audio::Score::Checks.plays_once!(score)
        end
        [score.length, score.loop_from].grep(DSL::PackNumber).each do |number|
          refuse_slot_from_elsewhere!(number.slot, "#{verb} reading a song's length from slot :#{number.slot.layout.name}")
        end
        parts = score.parts.map do |part|
          part = part.with(plays: pack_wave_in_start_file(part.plays, verb)) if part.plays.is_a?(DSL::PackWave)
          next part unless pack_notes?(part.notes)

          handle = part.notes.is_a?(DSL::PackSlot) ? part.notes.notes : part.notes
          refuse_slot_from_elsewhere!(handle.slot, "#{verb} reading notes from slot :#{handle.slot.layout.name}")
          part.with(notes: handle)
        end
        score.with(parts: parts)
      end

      def refuse_pack_score_without_length!(score, verb)
        unless score.length
          raise ArgumentError, "#{verb} has a Score that reads notes from the data pack, and this build reads its pack " \
                               "as the game starts. The build cannot know where the last note ends. To fix this, give " \
                               "the Score its length in ticks, like `length: 864`, or a number of the pack with the most " \
                               "it can be, like `length: pack[:song].number(0), longest: 2000`. Or build the game all-in-one."
        end
        return unless score.length.is_a?(DSL::PackNumber) && score.longest.nil?

        raise ArgumentError, "#{verb} has a Score that reads its length from the data pack, and this build reads its pack " \
                             "as the game starts. The build must know the most ticks the song can last. To fix this, " \
                             "give the Score `longest:`, like `longest: 2000`. Or build the game all-in-one."
      end

      # A part written in the game has its notes worked out as the game is built, which takes the
      # song's length and where it comes round. Read from the pack, those are known only as it starts.
      def refuse_pack_timing_beside_written_parts!(score, verb)
        return unless pack_timing?(score) && !score.parts.all? { |part| pack_notes?(part.notes) }

        raise ArgumentError, "#{verb} has a Score that reads its length or its loop from the data pack, and a part whose " \
                             "notes are written in the game. The build cannot work that part's notes out without the " \
                             "song's length. To fix this, read every part's notes from the pack, or give the length " \
                             "and the loop as numbers."
      end

      # THE SONG A SCORE MAKES (Audio::Score#to_song), where some of its parts read their notes
      # from the pack as the game starts. Such a part is made with no notes, so everything else
      # about it is worked out as for any part, and then keeps where its notes are in the start
      # file and what turns them into events (an IR::StartFile::Notes). Every backend that plays
      # the program makes the part's events from the file by that one rule.
      #
      # A song whose length or loop is a number of the pack is made as one +longest+ ticks long that
      # comes round to its start, and keeps where those numbers are (an IR::StartFile::SongLength).
      def song_reading_notes_at_start(score)
        emptied = score.with(parts: score.parts.map { |part| part.notes.is_a?(DSL::PackNotes) ? part.with(notes: []) : part },
                             length: score.length.is_a?(DSL::PackNumber) ? score.longest : score.length,
                             loop_from: (score.loop_from unless score.loop_from.is_a?(DSL::PackNumber)))
        song = emptied.to_song
        # Only the song's first square part slides (Guardrails::Checks::SlideOffFirstSquare).
        sliding = song.fetch(:voices).index { |voice| IR::Tunes.part_kind(voice) == :square }
        voices = song.fetch(:voices).each_with_index.map do |voice, number|
          handle = score.parts[number].notes
          next voice unless handle.is_a?(DSL::PackNotes)

          voice.with(from_file: pack_notes_in_start_file(handle, emptied, number, recorded: !voice.instrument.nil?,
                                                                                  takes_slide: number == sliding))
        end
        song = song.merge(voices: voices)
        return song unless pack_timing?(score)

        song.merge(length_from_file: IR::StartFile::SongLength.new(length: pack_number_in_start_file(score.length),
                                                                    loop_from: pack_number_in_start_file(score.loop_from),
                                                                    tempo: score.tempo, ticks_per_beat: score.ticks_per_beat))
      end

      # Where part +number+ of +score+ reads its notes in the start file. Only a part that plays
      # a recording picks an instrument for a note, so any other part names none.
      def pack_notes_in_start_file(handle, score, number, recorded:, takes_slide:)
        slot = handle.slot.layout
        instruments = recorded ? handle.instruments.map { |named| named.is_a?(Symbol) ? named : named.name } : []
        # A wave of the pack a note names is read from where it is in the start file, as a part's is.
        waves = handle.waves.map { |wave| wave.is_a?(DSL::PackWave) ? pack_wave_in_start_file(wave, "A song") : written_wave(wave) }
        notes = IR::StartFile::Notes.new(at: @pack_slot_starts.fetch(slot.name), count: slot.count, instruments: instruments.freeze,
                                         part: score.parts[number], tempo: score.tempo, ticks_per_beat: score.ticks_per_beat,
                                         who: "Part #{number} of a Score", recorded: recorded,
                                         voiced: slot.shape == :voiced_notes, takes_slide: takes_slide, waves: waves.freeze)
        refuse_keys_part_cannot_play!(notes, slot)
        notes
      end

      # The build works out what every key comes to on the part's voice, since any of them may be
      # in the pack. A part that moves its pitch can move a key past what its voice plays.
      def refuse_keys_part_cannot_play!(notes, slot)
        notes.key_events
        notes.pitch_number_events
      rescue ArgumentError => e
        raise ArgumentError, "#{notes.who} reads its notes from slot :#{slot.name} as the game starts, so it must be able " \
                             "to play every key from 0 to #{IR::StartFile::MOST_KEY}. It cannot: #{e.message}"
      end

      # The Score::Note list the slot of notes +part+ (a Score::Part) names holds. A voiced record's
      # settings (Original::PackNote#score_settings) are the note's own words, so the part's voice
      # refuses what it cannot play as it refuses a note written by hand.
      def notes_read_from_pack(part, verb)
        handle = part.notes.is_a?(DSL::PackSlot) ? part.notes.notes : part.notes
        subject = "#{verb} reading notes from slot :#{handle.slot.layout.name}"
        refuse_slot_from_elsewhere!(handle.slot, subject)
        recorded = recorded_part?(part)
        clocked = IR::StartFile.takes_clock?(part)
        handle.slot.layout.decode(@data_pack_contents.bytes_of(handle.slot.layout.name)).map do |note|
          refuse_unnamed_side_or_clock!(note, subject, side: !recorded && note.shade.nil?, clock: clocked)
          refuse_voice_settings_out_of_range!(note, subject)
          key = note.key unless note.key == Original::PackNote::REST
          clock = note.clock if key && clocked
          settings = key ? note.score_settings : {}
          # A noise clock is played in place of a pitch between keys, as IR::StartFile.notes_in plays it.
          settings.delete(:hz) if clock
          pitch = settings.delete(:pitch_number)
          # A voiced record's shade is the note's in place of its speaker, on a recorded part too.
          pan = settings.key?(:pan) ? settings.delete(:pan) : (note.side unless recorded)
          # A gliding note carries on the one sounding, with its instrument and volume (Original::PackNote).
          glides = settings[:glides]
          wave = pack_note_wave(note, handle.waves, subject, verb) if key && note.wave
          Audio::Score::Note.new(at: note.at, length: (note.length unless note.length.zero?), key: (key unless clock || pitch || settings[:hz]),
                                 volume: (pack_note_volume(note, recorded, subject) unless glides),
                                 instrument: (pack_note_instrument(note, handle.instruments, subject) unless glides),
                                 pan: pan, noise_clock: clock, pitch_number: pitch, wave: wave, **settings)
        end
      end

      # A wave the game wrote in a part's `notes(waves: [...])`: a shape or 32 steps, as a note's
      # `wave:` keeps it (Audio::Score::Note#own_wave).
      def written_wave(wave)
        Audio::Music.resolve_plays(wave)[:wave] or
          raise ArgumentError, "`notes(waves: [...])` names #{wave.inspect}. A wave is a shape " \
                               "(#{Audio::Music::WAVE_SHAPES.map(&:inspect).join(', ')}), #{Audio::Sound::WAVE_SAMPLES} steps " \
                               "of 0 to #{Audio::Sound::WAVE_STEP_MAX}, or a wave of the pack, like `pack[:waves].wave(0)`. " \
                               "Give one of those."
      end

      # The wave a voiced record names among the part's +waves+ (`notes(waves: [...])`), as a note's
      # `wave:` takes it: a wave of the pack read here as its steps.
      def pack_note_wave(note, waves, subject, verb)
        wave = waves.fetch(note.wave) do
          raise ArgumentError, "#{subject}: the note at tick #{note.at} plays wave #{note.wave}. The part names " \
                               "#{waves.length} waves. To fix this, name every wave its notes play, like " \
                               "`notes(waves: [pack[:waves].wave(0), :sine])`."
        end
        wave.is_a?(DSL::PackWave) ? pack_wave_steps(wave, verb) : written_wave(wave)
      end

      def refuse_voice_settings_out_of_range!(note, subject)
        out = note.settings_out_of_range
        return if out.empty?

        raise ArgumentError, "#{subject}: the note at tick #{note.at} names a #{out.first.to_s.tr('_', ' ')} out of its range " \
                             "(Original::PackNote says each range). To fix this, correct the record, or leave the setting " \
                             "out of the record's names to play the part's own."
      end

      def recorded_part?(part) = Audio::Score::Checks.recording?(Audio::Music.resolve_plays(part.plays))

      # A record's speaker and noise clock each name one, or the part's own (Original::PackNote),
      # where the part takes them (+side+, +clock+); elsewhere they mean nothing.
      def refuse_unnamed_side_or_clock!(note, subject, side:, clock:)
        if side && !note.side_named?
          raise ArgumentError, "#{subject}: the note at tick #{note.at} has the speaker #{note.pan}. A speaker is 0 for both, 1 " \
                               "for the left or 2 for the right, or #{Original::PackNote::PART_OWN} for the part's own."
        end
        return if !clock || note.clock_named?

        raise ArgumentError, "#{subject}: the note at tick #{note.at} has the noise clock #{note.noise_clock}. A noise clock " \
                             "has its divider, 0 to 7, in the low three bits and its halvings, 0 to 13, in the high four. " \
                             "Write #{Original::PackNote::PART_OWN} to play the note's key."
      end

      # A note's volume: its loudness in 512ths as a volume with a fraction on a part that plays a
      # recording (Original::PackNote), else its volume, nil for the part's own.
      def pack_note_volume(note, recorded, subject)
        loudness = note.loudness
        return (note.volume unless note.volume == Original::PackNote::PART_OWN) if !recorded || loudness == Original::PackNote::NO_LOUDNESS
        return Rational(IR::StartFile::MOST_VOLUME * loudness, Original::PackNote::FULL_LOUDNESS) if loudness <= Original::PackNote::FULL_LOUDNESS

        raise ArgumentError, "#{subject}: the note at tick #{note.at} has the loudness #{loudness}. A loudness is 512ths of the " \
                             "recording's size, 0 to #{Original::PackNote::FULL_LOUDNESS}, or #{Original::PackNote::NO_LOUDNESS} " \
                             "to take the note's volume."
      end

      def pack_note_instrument(note, instruments, subject)
        return nil if note.instrument == Original::PackNote::PART_OWN

        instruments.fetch(note.instrument) do
          raise ArgumentError, "#{subject}: the note at tick #{note.at} plays instrument #{note.instrument}. The part names " \
                               "#{instruments.length} instruments. To fix this, name every instrument its notes play, " \
                               "like `notes(instruments: %i[horn bass])`."
        end
      end

      # +value+ for an instrument's setting, a number of the pack read here (DSL::PackNumber) or the
      # game's own. With the pack left out a number of the pack is +stand_in+, which the recording
      # holds until the file is read (#recording_settings_in_start_file says where from).
      def pack_setting_value(value, subject, stand_in)
        return value unless value.is_a?(DSL::PackNumber)

        if pack_left_out?
          refuse_slot_from_elsewhere!(value.slot, subject)
          return stand_in
        end
        pack_slot_values(value.slot, :numbers, subject).fetch(value.index)
      end

      # +envelope+ for an instrument, an envelope of the pack read here (DSL::PackEnvelope) as the
      # four numbers an Audio::Envelope keeps, or the game's own. With the pack left out it is a
      # stand-in, as a number is.
      # A DSL::PackSNESEnvelope is read as the three bytes an Audio::SNESEnvelope keeps.
      def pack_envelope_value(envelope, subject)
        case envelope
        when DSL::PackEnvelope
          if pack_left_out?
            refuse_slot_from_elsewhere!(envelope.slot, subject)
            return IR::StartFile.recording_stand_in_envelope
          end
          attack, decay, sustain, release = pack_slot_values(envelope.slot, :numbers, subject).slice(envelope.index * 4, 4)
          Audio::Envelope.new(attack: attack, decay: decay, sustain: sustain, release: release)
        when DSL::PackSNESEnvelope
          if pack_left_out?
            refuse_slot_from_elsewhere!(envelope.slot, subject)
            return IR::StartFile.recording_stand_in_envelope
          end
          # The bytes as the file keeps them, as a runtime reads them (IR::StartFile.envelope_in).
          adsr1, adsr2, gain = pack_slot_values(envelope.slot, :numbers, subject).slice(envelope.index * 3, 3).map { |byte| byte & 0xFF }
          Audio::SNESEnvelope.new(adsr1: adsr1, adsr2: adsr2, gain: gain)
        else envelope
        end
      end

      # WHERE A RECORDING'S SETTINGS ARE IN THE START FILE (an IR::StartFile::RecordingSettings),
      # for those of +rate+, +holds_from+ and +envelope+ that are numbers of the pack, with the pack
      # left out; nil for a recording that reads none of them from there. A slot's place and the
      # width of its numbers are the game's own words, so the build knows where each number will
      # be without knowing it. +brr+ is where a recording in the Super Nintendo chip's format is
      # (an IR::StartFile::BRR), or nil.
      def recording_settings_in_start_file(rate:, holds_from:, envelope:, length: nil, brr: nil)
        return nil unless pack_left_out?

        settings = IR::StartFile::RecordingSettings.new(rate: pack_number_in_start_file(rate),
                                                        holds_from: pack_number_in_start_file(holds_from),
                                                        envelope: pack_envelope_in_start_file(envelope),
                                                        length: pack_number_in_start_file(length), brr: brr)
        settings unless settings.to_h.values.all?(&:nil?)
      end

      # Where +envelope+ is in the start file (an IR::StartFile::EnvelopeBytes), for an envelope of
      # the pack: four bytes, or three kept as the Super Nintendo's sound chip keeps them.
      def pack_envelope_in_start_file(envelope)
        case envelope
        when DSL::PackEnvelope
          IR::StartFile::EnvelopeBytes.new(at: @pack_slot_starts.fetch(envelope.slot.layout.name) + (envelope.index * 4),
                                           kept_as: :envelope)
        when DSL::PackSNESEnvelope
          IR::StartFile::EnvelopeBytes.new(at: @pack_slot_starts.fetch(envelope.slot.layout.name) + (envelope.index * 3),
                                           kept_as: :snes_envelope)
        end
      end

      def pack_number_in_start_file(value)
        return nil unless value.is_a?(DSL::PackNumber)

        slot = value.slot.layout
        IR::StartFile::Number.new(at: @pack_slot_starts.fetch(slot.name) + (value.index * slot.item_bytes),
                                  width: slot.width, signed: slot.signed, format: slot.format)
      end

    end
  end
end
