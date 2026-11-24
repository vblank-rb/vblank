# frozen_string_literal: true

module VBlank
  module Testing
    # One game's heard sound held to another's, in a test: a port's cartridge beside the original it
    # is made from, the same presses on both in the same emulator. It is the one assertion for what
    # comes out of the speakers, over Playthroughs::HeardComparison, as PlaysAlike is for the picture:
    #
    #   class TitleTuneTest < Minitest::Test
    #     include VBlank::Testing::HeardAlike
    #
    #     def test_the_title_tune_is_heard_as_the_originals_is
    #       assert_heard_alike ours, ORIGINAL.copy.path, to_the_end_of_the_tune,
    #                          heard_above: 0,                # the emulator's silence is exactly nought
    #                          first_heard_frames_apart: 0,   # the first note starts on the original's frame
    #                          level_share_apart: 0.1,        # a tenth: the two mix a chord in another order
    #                          ending_frames_apart: 6         # the last chord's fall is rounded another way
    #     end
    #   end
    #
    # +first+ and +second+ are cartridges (built ones, or files by their path: an original on any
    # console whose emulator hands its sound over), and +presses+ a tape or a VBlank.playthrough,
    # whose script is played on the first and the presses it made on the second. Every setting is
    # the game's to give, with its reason beside it, and none has a value this assumes:
    #
    #   heard_above:               the loudest sample a frame may have and still count as silent
    #   first_heard_frames_apart:  how many frames apart the two may first be heard
    #   level_share_apart:         how far apart their levels may be, as a share of the louder one's
    #   ending_frames_apart:       how many frames apart they may be last heard, and their last
    #                              sounds may take to fall silent
    #   lead_ins:                  a playthrough for each to play first, not counted (optional)
    #   level_stretch_frames:      hold the level this many frames at a time, not as one average (optional)
    #   pitch_cents_apart:         how far apart in pitch each voice may be on a frame both are heard on,
    #                              in cents (a semitone is 100), so a wrong note fails naming the voice
    #                              and the frame (optional); each voice is played alone on both to hear
    #                              it, on a console whose emulator plays a voice alone
    #   line_up_within_frames:     move the second's sound up to this many frames earlier or later, to
    #                              where it lines up best with the first's, before comparing (optional),
    #                              for two whose start-up takes a few frames more on one; the failure
    #                              says how far it was moved
    #   each_speaker: false        compare the speakers mixed alone, for two that place their sound
    #                              differently on purpose (each speaker is compared too unless set)
    #   each_voice: false          after a difference, do not play each voice alone to name the one
    #                              that differs (it plays the tape again twice for each voice)
    #   hearing:                   the voices heard on each side, the first cartridge's and then the
    #                              second's, by the names the console's reader gives them
    #                              (`hearing: [[:square2], [:square1]]`), for one sound held to the
    #                              original's on whichever voice each plays it, while the rest differs;
    #                              a side can be :sound_effects, that cartridge's effects alone on
    #                              whichever voices its player put them each frame
    #                              (`hearing: [:sound_effects, [:voice0]]`)
    #   starting_after:            a frame of the tape, or the name of one of its moments, to play both
    #                              to unheard and compare from the frame after (optional), with
    #   snapshots:                 a Playthroughs::SnapshotCache that keeps each console on that frame,
    #                              so a moment deep in a tape costs the frames heard; every measure is
    #                              of the frames after the start, counted from power-on. Give a tape,
    #                              not a playthrough. On the Super Nintendo and the Genesis the
    #                              emulator's sound after a snapshot drifts a little from the
    #                              console's, so a strict level_share_apart can find a level apart
    #                              warm that it would not cold
    #   wav:                       a path to write both sounds to, for a person to hear (optional), with
    #   wav_layout:                :in_turn (the first, then the second) or :side_by_side (the first on
    #                              the left speaker, the second on the right); :in_turn if left out
    #
    # A failure names every measure that was out at once, what each cartridge measured, the first
    # frame the two differ on and the loudest sample each put out on it; a measure out on one speaker
    # alone, naming the speaker; and, on a console whose emulator plays a voice alone, which voices
    # differ played alone and how (Playthroughs::HeardComparison).
    #
    # It plays both in the emulator, so the game's test group needs the emulator gems.
    #
    # A game whose original is not a cartridge holds its sound to a recording instead, a .wav file, with
    # #assert_sounds_like.
    module HeardAlike
      def assert_heard_alike(first, second, presses, message = nil, wav: nil, wav_layout: :in_turn, **settings)
        compared = Playthroughs::HeardComparison.play(presses, first, second, **settings)
        compared.write_wav(wav, layout: wav_layout) if wav
        assert compared.alike?, (compared.alike? ? nil : [message, HeardAlike.difference_message(compared)].compact.join("\n"))
      end

      # Ours held to a recording, for a game whose original is not a cartridge: the original's music
      # rendered to a .wav file by an accurate emulator of its sound chip, say. Compared as a person
      # hears it, not sample for sample (Diagnostics::RecordingComparison):
      #
      #   assert_sounds_like ours, "reference/title.wav", to_the_end_of_the_song,
      #                      quiet_below_db: 40,          # 40 dB down is near silence
      #                      loudness_db_apart: 3,        # the ear hears 3 dB as a small step
      #                      mel_db_apart: 6,             # the 8-bit mix rounds every band a little
      #                      noise_floor_db_apart: 24,    # 8 bits with dither hiss that much over 16
      #                      rolloff_hz_apart: 2000       # 22,050 a second carries less of the top
      #
      # +ours+ and +reference+ are each a cartridge (built, or a file by its path) played on +presses+
      # from power-on, a .wav file by its path, or a Diagnostics::SoundRecording. Each is heard from its
      # first sound. Every tolerance is the game's to give, with its reason (RecordingTolerances).
      # +lead_in+ is a playthrough a cartridge plays first, not heard; +wav:+ and +wav_layout:+ write
      # both, as #assert_heard_alike's do. A failure names every measure out at once, where each first
      # is out in seconds and frames from the first sound, and what was measured of both.
      def assert_sounds_like(ours, reference, presses = nil, message = nil, lead_in: nil, wav: nil, wav_layout: :in_turn,
                             **tolerances)
        heard = HeardAlike.recording_of(ours, presses, lead_in: lead_in)
        expected = HeardAlike.recording_of(reference, presses, lead_in: lead_in, frame_seconds: heard.frame_seconds)
        compared = Diagnostics::RecordingComparison.between(heard, expected, **tolerances)
        Diagnostics::SoundRecording.write_pair(wav, heard, expected, layout: wav_layout) if wav
        assert compared.alike?,
               (compared.alike? ? nil : [message, HeardAlike.recording_difference_message(compared)].compact.join("\n"))
      end

      # +given+ as a SoundRecording: one already, a .wav file read, or a cartridge played on +presses+.
      def self.recording_of(given, presses, lead_in:, frame_seconds: nil)
        return given if given.is_a?(Diagnostics::SoundRecording)
        if given.is_a?(String) && File.extname(given).casecmp?(".wav")
          return Diagnostics::SoundRecording.read_wav(given, frame_seconds: frame_seconds || Console.described(:gba).frame_seconds)
        end

        unless presses
          raise ArgumentError, "A cartridge is heard as it plays presses, and none were given. To fix this, give a tape or " \
                               "a playthrough after the two sounds: `assert_sounds_like ours, \"title.wav\", listen, ...`."
        end
        played = presses.play(given, lead_in: lead_in)
        Diagnostics::SoundRecording.heard_in(played.game, frames: played.frames)
      end

      # The words of a failure of #assert_sounds_like: a line for each measure out, then what was
      # measured of both.
      def self.recording_difference_message(compared)
        lines = compared.differences.map { |difference| recording_measure_words(difference) }
        lines << recording_measures_words(compared.measures) if compared.measures
        lines.join("\n")
      end

      def self.recording_measure_words(difference)
        one, other = difference.measured
        where = difference.seconds && "It is first out #{format('%.2f', difference.seconds)} s from the first sound, " \
                                      "on frame #{difference.frame}#{over_words(difference)}."
        words = case difference.what
                when :never_heard
                  "#{one ? 'The reference' : 'Ours'} is never heard, so there is nothing to compare."
                when :loudness
                  "The loudness differs: #{decibel_words(one)} on ours and #{decibel_words(other)} on the reference, once their loud " \
                    "moments are matched."
                when :tone
                  "The tone differs: the mel-spectrum distance is #{format('%.1f', one)} dB."
                when :noise_floor
                  "Ours has more noise in the quiet: #{decibel_words(one)} on ours and #{decibel_words(other)} on the reference."
                when :muffled
                  "Ours is muffled: its high sounds stop at #{one.round} Hz and the reference's at #{other.round} Hz, " \
                    "on average."
                end
        [words, where].compact.join(" ")
      end

      def self.over_words(difference) = difference.moments_over ? ", one of #{difference.moments_over} moments out" : ""

      def self.recording_measures_words(measures)
        floors = measures.noise_floors_db&.map { |level| decibel_words(level) }&.join(" and ") || "not measured, no quiet moment"
        rolloffs = measures.rolloffs_hz&.map(&:round)&.join(" Hz and ")
        "Measured, ours then the reference: #{format('%.1f', measures.seconds[0])} s and " \
          "#{format('%.1f', measures.seconds[1])} s long from the first sound; the reference #{decibel_words(measures.gain_db)} " \
          "louder; noise floors #{floors}; high sounds stop at #{rolloffs || '-'} Hz; dynamic ranges " \
          "#{measures.dynamic_ranges_db.map { |range| format('%.1f dB', range) }.join(' and ')}; the worst tone " \
          "distance #{format('%.1f', measures.worst_mel_db || 0)} dB over #{measures.moments_compared} moments."
      end

      def self.decibel_words(level) = format("%.1f dB", level)

      # The words of a failure of #assert_heard_alike (Playthroughs::HeardReport).
      def self.difference_message(compared) = Playthroughs::HeardReport.difference_message(compared)

      private_class_method :recording_measure_words, :over_words, :recording_measures_words, :decibel_words
    end
  end
end
