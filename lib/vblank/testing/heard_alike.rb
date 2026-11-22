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
    #   each_speaker: false        compare the speakers mixed alone, for two that place their sound
    #                              differently on purpose (each speaker is compared too unless set)
    #   each_voice: false          after a difference, do not play each voice alone to name the one
    #                              that differs (it plays the tape again twice for each voice)
    #   hearing:                   the voices heard on each side, the first cartridge's and then the
    #                              second's, by the names the console's reader gives them
    #                              (`hearing: [[:square2], [:square1]]`), for one sound held to the
    #                              original's on whichever voice each plays it, while the rest differs
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

      # The words of a failure: a line for each measure out, saying what each side measured and the
      # first frame they differ on, a speaker's own named; then, where each voice was played alone,
      # which voices differ and how.
      def self.difference_message(compared)
        lines = compared.differences.map do |difference|
          speaker = "On the #{difference.speaker} speaker alone: " if difference.speaker
          "#{speaker}#{[measure_words(difference, compared), frame_words(difference)].compact.join(' ')}"
        end
        (hearing_lines(compared.hearing) + lines + voice_lines(compared.voices)).join("\n")
      end

      # The voices the game chose to hear on each side (`hearing:`), first: every measure is of them.
      def self.hearing_lines(hearing)
        return [] if hearing.nil?

        first, second = hearing.map { |voices| voice_list_words(voices) }
        ["Heard alone: #{first} on the first cartridge and #{second} on the second."]
      end

      def self.voice_list_words(voices)
        *most, last = voices
        "the #{most.empty? ? last : "#{most.join(', ')} and #{last}"} #{voices.size == 1 ? 'voice' : 'voices'}"
      end

      # Each voice that differs played alone, by name, and the voices alike.
      def self.voice_lines(voices)
        return [] if voices.nil?
        return ["No voice can be played alone on this console's emulator, so the voice that differs is not named."] if voices.empty?

        # A voice neither cartridge sounds is alike, though a comparison of nothing finds nothing heard.
        differing, alike = voices.partition { |_, compared| !compared.alike? && (compared.first.heard? || compared.second.heard?) }
        if differing.empty?
          return ["Played a voice at a time, every voice is alike: the difference is in how they sound together."]
        end

        differing.map { |voice, compared| "Played alone, the #{voice} voice differs:\n  #{difference_message(compared).gsub("\n", "\n  ")}" } +
          (alike.empty? ? [] : ["Played alone, these voices are alike: #{alike.map(&:first).join(', ')}."])
      end

      def self.measure_words(difference, compared)
        one, other = difference.measured
        case difference.what
        when :never_heard then never_heard_words(difference.speaker ? compared.speakers.fetch(difference.speaker) : [compared.first, compared.second])
        when :first_heard
          "The two cartridges are first heard on different frames: frame #{one} on the first and frame #{other} on the second."
        when :level then level_words(difference)
        when :last_heard
          "The two cartridges are last heard on different frames: frame #{one} on the first and frame #{other} on the second."
        when :fall
          "The last sound takes a different time to fall silent: #{one} frames on the first cartridge and #{other} on the second."
        end
      end

      # Both levels, and how many times as loud the louder is: a share of the louder reads oddly where
      # one is several times the other.
      def self.level_words(difference)
        one, other = difference.measured
        over = if difference.frames
                 "over frames #{difference.frames.first} to #{difference.frames.last}, the first of " \
                   "#{difference.stretches_over} stretches out"
               else
                 "averaged over the frames each is heard"
               end
        "The two cartridges are heard at different levels: #{one.round} on the first and #{other.round} on the second, " \
          "the loudest sample a frame #{over}. #{times_as_loud_words(one, other)}"
      end

      def self.times_as_loud_words(one, other)
        return "The #{one.zero? ? 'first' : 'second'} is silent there." if [one, other].min.zero?

        louder, quieter = one >= other ? %w[first second] : %w[second first]
        "So the #{louder} is #{format('%.1f', [one, other].max.fdiv([one, other].min))} times as loud as the #{quieter}."
      end

      # +pair+ is the two HeardSounds, the first cartridge's and the second's.
      def self.never_heard_words(pair)
        sides = { "first" => pair[0], "second" => pair[1] }
        silent, heard = sides.partition { |_, side| !side.heard? }
        limit = "above #{pair[0].heard_above} in #{pair[0].frames} frames"
        return "Neither cartridge is heard #{limit}, so there is nothing to compare." if heard.empty?

        "The #{silent.first.first} cartridge is never heard #{limit}. The #{heard.first.first} is first heard on " \
          "frame #{heard.first.last.first_heard}."
      end

      def self.frame_words(difference)
        return unless difference.frame

        "They first differ on frame #{difference.frame}: the loudest sample is #{difference.loudest[0]} on the first " \
          "and #{difference.loudest[1]} on the second."
      end
      private_class_method :hearing_lines, :voice_list_words, :voice_lines, :measure_words, :level_words, :times_as_loud_words, :never_heard_words, :frame_words,
                           :recording_measure_words, :over_words, :recording_measures_words, :decibel_words
    end
  end
end
