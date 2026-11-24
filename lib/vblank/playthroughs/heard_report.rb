# frozen_string_literal: true

module VBlank
  module Playthroughs
    # The words of a HeardComparison that found the two cartridges unlike, for a person: what a failed
    # Testing::HeardAlike#assert_heard_alike says, and what `vblank compare --sound` prints.
    module HeardReport
      # A line for each measure out, saying what each side measured and the first frame they differ
      # on, a speaker's or a voice's own named; first the voices chosen and how far the second was
      # moved, where either was; then, where each voice was played alone, which voices differ and how.
      def self.difference_message(compared)
        lines = compared.differences.map do |difference|
          alone = "On the #{difference.speaker} speaker alone: " if difference.speaker
          alone = "On the #{difference.voice} voice alone: " if difference.voice
          "#{alone}#{[measure_words(difference, compared), frame_words(difference)].compact.join(' ')}"
        end
        (hearing_lines(compared.hearing) + moved_lines(compared.moved_frames) + lines + voice_lines(compared.voices) +
          unread_pitch_lines(compared.voices)).join("\n")
      end

      # How far the second cartridge's sound was moved to line up with the first's
      # (`line_up_within_frames:`), first: every frame after is of the second as moved. Public for
      # `vblank compare --sound`, which says it of two that sound alike too.
      def self.moved_lines(frames)
        return [] if frames.nil?
        return ["The two cartridges' sounds were lined up as they are: neither was moved."] if frames.zero?

        ["The second cartridge's sound was moved #{frames.abs} #{frames.abs == 1 ? 'frame' : 'frames'} " \
         "#{frames.positive? ? 'earlier' : 'later'} to line up with the first's."]
      end

      # The voices the game chose to hear on each side (`hearing:`), first: every measure is of them.
      def self.hearing_lines(hearing)
        return [] if hearing.nil?

        first, second = hearing.map { |voices| voice_list_words(voices) }
        ["Heard alone: #{first} on the first cartridge and #{second} on the second."]
      end

      def self.voice_list_words(voices)
        return "the sound effects, on the voices they held" if voices == HeardComparison::SOUND_EFFECTS

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
        when :pitch then pitch_words(difference)
        when :no_pitch then no_pitch_words
        end
      end

      # Both pitches on the first frame out, how far apart they are, and on how many frames.
      def self.pitch_words(difference)
        one, other = difference.measured
        apart = " #{HeardComparison.cents_apart(one, other).round} cents apart. A semitone is 100 cents" if one && other
        "The two cartridges are heard at different pitches on #{difference.frames_over} " \
          "#{difference.frames_over == 1 ? 'frame' : 'frames'}: #{hertz_words(one)} on the first and " \
          "#{hertz_words(other)} on the second,#{apart || ' where both are heard'}."
      end

      def self.hertz_words(pitch) = pitch ? "#{format('%.1f', pitch)} Hz" : "no pitch"

      # The pitch was asked for, and the voices heard have none on any frame both are heard on.
      def self.no_pitch_words
        "Neither cartridge has a pitch on any frame both are heard on, so no pitch was held. The voices heard are a " \
          "noise, a drum, or more than one note at once. To hold a pitch, choose one voice a side with `hearing:`, or " \
          "remove `pitch_cents_apart:`."
      end

      # The voices played alone whose pitch was not held because neither cartridge had one there.
      def self.unread_pitch_lines(voices)
        unread = (voices || {}).select { |_, compared| compared.pitch_unread }.keys
        return [] if unread.empty?

        ["Played alone, #{unread.join(', ')} #{unread.one? ? 'has' : 'have'} no pitch on either cartridge, so " \
         "#{unread.one? ? 'its' : 'their'} pitch was not held."]
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
      private_class_method :hearing_lines, :voice_list_words, :voice_lines, :measure_words, :level_words,
                           :pitch_words, :hertz_words, :no_pitch_words, :times_as_loud_words, :never_heard_words,
                           :frame_words
    end
  end
end
