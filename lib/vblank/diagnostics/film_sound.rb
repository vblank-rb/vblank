# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The sound of a film (Film), asked for with Film.make's +sound:+: what each side put out on the
    # frames the film shows, laid under the pictures so each frame's sound plays while that frame is
    # on screen. A film with no sound asked for has no sound in it at all, and Film never makes one.
    #
    # Which sides are heard, by the +sound:+ setting:
    #
    #   "ours"          that side alone, as it made it, on both speakers
    #   :side_by_side   two sides at once: the first on the left speaker, the second on the right,
    #                   each side's two speakers made one
    #   :in_turn        the film shown once for each side, in the order of +sides:+, and each time
    #                   one side heard, as it made it
    #
    # In step with the pictures. A console's frame is a little longer than the film's sixtieth of a
    # second (Console::Description#frame_seconds), and its sound comes at its own rate. So each part's
    # sound, its frames' samples one after another, is stretched or squeezed to the film frames that
    # show the part: the sound of a frame plays while that frame is shown, however far into a long
    # part. It plays as much faster than the console as the pictures do, which no ear can tell. A
    # frame that put out nothing (a lowering held back for its cartridge's start) is a frame of
    # silence, and so are the frames a part's end and the film's end are held for.
    #
    # A side is heard through `last_frame_samples`: the samples of the frame it played last, the left
    # speaker's then the right's, a moment at a time, as the emulator's reader (Verifier), a lowering
    # (Playthroughs::LoweredGame) and a shell's sides (FilmShell) answer it.
    class FilmSound
      # The film's sound is written at this many samples a second for each speaker: a whole number of
      # them in each of the film's frames.
      RATE = 48_000
      SAMPLES_PER_FILM_FRAME = RATE / Film::FRAME_RATE

      # The words +sound:+ takes besides a side's label.
      SIDE_BY_SIDE = :side_by_side
      IN_TURN = :in_turn
      SETTINGS = [SIDE_BY_SIDE, IN_TURN].freeze

      # Each heard side's label, given +setting+ (Film.make's +sound:+) and the film's side +labels+,
      # in the order they are heard; refused in plain words before any side opens.
      def self.heard_labels(setting, labels)
        case setting
        when SIDE_BY_SIDE
          refuse_side_by_side_count!(labels)
          labels
        when IN_TURN then labels
        when String, Symbol then [refuse_unknown_side!(setting.to_s, labels)]
        else refuse_unknown_setting!(setting, labels)
        end
      end

      def self.refuse_side_by_side_count!(labels)
        return if labels.size == 2

        raise ArgumentError, "`sound: :side_by_side` puts one side on each speaker, so it needs two sides. This film " \
                             "has #{labels.size}. To fix this, give two sides, or hear one side with " \
                             "`sound: #{labels.first.inspect}`, or each side in turn with `sound: :in_turn`."
      end

      def self.refuse_unknown_side!(label, labels)
        return label if labels.include?(label)

        raise ArgumentError, "`sound: #{label.inspect}` names no side of this film. The sides are " \
                             "#{labels.map(&:inspect).join(', ')}. To fix this, give one of them, `sound: :side_by_side` " \
                             "or `sound: :in_turn`."
      end

      def self.refuse_unknown_setting!(setting, labels)
        raise ArgumentError, "`sound:` was #{setting.inspect}. Give the label of the side to hear " \
                             "(`sound: #{labels.first.inspect}`), `sound: :side_by_side` for two sides, one on each " \
                             "speaker, or `sound: :in_turn` to show the film once for each side."
      end
      private_class_method :refuse_side_by_side_count!, :refuse_unknown_side!, :refuse_unknown_setting!

      # +setting+ is Film.make's +sound:+, already checked (FilmSound.heard_labels); +parts+ the film's
      # ranges of frames and +holds+ how many film frames each shown frame is held for (Film#hold_lengths).
      def initialize(setting, parts:, holds:)
        @setting = setting
        @parts = parts
        @holds = holds
        @heard = {}
      end

      # How many times the pictures are shown: once for each side in turn, else once.
      def showings = @setting == IN_TURN ? @heard.size : 1

      # Keep the sound of every shown frame of the side +label+, from +samples_by_frame+ (a frame's number
      # to its samples, left and right by turns).
      def keep(label, samples_by_frame)
        @heard[label] = samples_by_frame
      end

      # The film's sound written to +path+ as a WAV file: two speakers of sixteen-bit samples at RATE.
      def write_wav(path)
        left, right = speakers
        data = left.zip(right).flatten.pack("s<*")
        header = ["RIFF", 36 + data.bytesize, "WAVE", "fmt ", 16, 1, 2, RATE, RATE * 4, 4, 16, "data", data.bytesize]
        File.binwrite(path, header.pack("a4Va4a4VvvVVvva4V") + data)
        path
      end

      private

      # The left speaker's samples and the right's, the length of the film.
      def speakers
        tracks = @heard.transform_values { |samples_by_frame| track(samples_by_frame) }
        case @setting
        when SIDE_BY_SIDE then tracks.values.map { |left, right| mixed(left, right) }
        when IN_TURN then [tracks.values.flat_map(&:first), tracks.values.flat_map(&:last)]
        else tracks.values.first
        end
      end

      # One side's two speakers, each the length of one showing of the film.
      def track(samples_by_frame)
        usual = usual_frame_length(samples_by_frame.values)
        left = []
        right = []
        held = 0
        @parts.each do |part|
          frames = part.to_a
          stream = frames.flat_map { |frame| frame_samples(samples_by_frame.fetch(frame), usual) }
          shown_for = frames.size * SAMPLES_PER_FILM_FRAME
          left.concat(stretched(stream.each_slice(2).map(&:first), shown_for))
          right.concat(stretched(stream.each_slice(2).map(&:last), shown_for))
          extra = @holds[held, frames.size].sum - frames.size
          held += frames.size
          silence = Array.new(extra * SAMPLES_PER_FILM_FRAME, 0)
          left.concat(silence)
          right.concat(silence)
        end
        [left, right]
      end

      # A frame's samples, or a frame's length of silence where it put out none.
      def frame_samples(samples, usual) = samples.empty? ? Array.new(usual, 0) : samples

      # How many samples a frame usually has, both speakers': the commonest length.
      def usual_frame_length(frames)
        lengths = frames.map(&:size).reject(&:zero?)
        lengths.empty? ? 0 : lengths.tally.max_by(&:last).first
      end

      # +samples+ made +length+ long, each new sample read between the two old ones it falls between.
      def stretched(samples, length)
        return Array.new(length, 0) if samples.empty?

        last = samples.size - 1
        step = samples.size.to_f / length
        Array.new(length) do |at|
          place = at * step
          below = place.floor.clamp(0, last)
          above = [below + 1, last].min
          (samples[below] + ((samples[above] - samples[below]) * (place - below))).round
        end
      end

      # Two speakers made one.
      def mixed(left, right) = left.zip(right).map { |one, other| (one + other) / 2 }
    end
  end
end
