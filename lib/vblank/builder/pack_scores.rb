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
    # number. A part's notes and a chip envelope are not made that way yet, and the build says so.
    module PackScores
      private

      # +scores+ (a list or a Hash of Audio::Score, for `songs` or `sound_effects`) with each part
      # whose notes are a slot of the pack given the notes the slot holds. +verb+ names the line.
      def scores_with_pack_notes(scores, verb)
        read = ->(score) { score.is_a?(Audio::Score) ? score_with_pack_notes(score, verb) : score }
        scores.is_a?(Hash) ? scores.transform_values(&read) : Array(scores).map(&read)
      end

      def score_with_pack_notes(score, verb)
        return score unless score.parts.any? { |part| pack_notes?(part.notes) }

        score.with(parts: score.parts.map { |part| pack_notes?(part.notes) ? part.with(notes: notes_read_from_pack(part.notes, verb)) : part })
      end

      def pack_notes?(notes) = notes.is_a?(DSL::PackNotes) || (notes.is_a?(DSL::PackSlot) && notes.shape == :notes)

      # The Score::Note list a slot of notes holds.
      def notes_read_from_pack(handle, verb)
        handle = handle.notes if handle.is_a?(DSL::PackSlot)
        subject = "#{verb} reading notes from slot :#{handle.slot.layout.name}"
        refuse_pack_read_while_left_out!(subject)
        refuse_slot_from_elsewhere!(handle.slot, subject)
        handle.slot.layout.decode(@data_pack_contents.bytes_of(handle.slot.layout.name)).map do |note|
          Audio::Score::Note.new(at: note.at, length: (note.length unless note.length.zero?),
                                 key: (note.key unless note.key == Original::PackNote::REST),
                                 volume: (note.volume unless note.volume == Original::PackNote::PART_OWN),
                                 instrument: pack_note_instrument(note, handle.instruments, subject))
        end
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
          refuse_chip_envelope_left_out!(subject)
          adsr1, adsr2, gain = pack_slot_values(envelope.slot, :numbers, subject).slice(envelope.index * 3, 3)
          Audio::SNESEnvelope.new(adsr1: adsr1, adsr2: adsr2, gain: gain)
        else envelope
        end
      end

      # WHERE A RECORDING'S SETTINGS ARE IN THE START FILE (an IR::StartFile::RecordingSettings),
      # for those of +rate+, +holds_from+ and +envelope+ that are numbers of the pack, with the pack
      # left out; nil for a recording that reads none of them from there. A slot's place and the
      # width of its numbers are the game's own words, so the build knows where each number will
      # be without knowing it.
      def recording_settings_in_start_file(rate:, holds_from:, envelope:)
        return nil unless pack_left_out?

        shape = if envelope.is_a?(DSL::PackEnvelope)
                  IR::StartFile::EnvelopeBytes.new(at: @pack_slot_starts.fetch(envelope.slot.layout.name) + (envelope.index * 4),
                                                   kept_as: :envelope)
                end
        settings = IR::StartFile::RecordingSettings.new(rate: pack_number_in_start_file(rate),
                                                        holds_from: pack_number_in_start_file(holds_from), envelope: shape)
        settings unless settings.to_h.values.all?(&:nil?)
      end

      def pack_number_in_start_file(value)
        return nil unless value.is_a?(DSL::PackNumber)

        slot = value.slot.layout
        IR::StartFile::Number.new(at: @pack_slot_starts.fetch(slot.name) + (value.index * slot.item_bytes),
                                  width: slot.width, signed: slot.signed, format: slot.format)
      end

      # An envelope as the Super Nintendo's sound chip keeps it is turned into the nearest ordinary
      # envelope as the game is built (Audio::SNESEnvelope#closest_envelope), from bytes a build
      # that leaves its pack out does not hold.
      def refuse_chip_envelope_left_out!(subject)
        return unless pack_left_out?

        raise ArgumentError, "#{subject} reads a Super Nintendo sound chip envelope from the data pack, and this build " \
                             "reads its pack as the game starts. A chip envelope from the pack is not made that way " \
                             "yet. To fix this, build the game all-in-one, or give the instrument four bytes with " \
                             "`pack[:slot].envelope(0)`."
      end

      def refuse_pack_read_while_left_out!(subject)
        return unless pack_left_out?

        raise ArgumentError, "#{subject} reads the data pack as the game is built, and this build reads its pack as the " \
                             "game starts. Notes and instrument settings from the pack are not made that way yet. To fix " \
                             "this, build the game all-in-one."
      end
    end
  end
end
