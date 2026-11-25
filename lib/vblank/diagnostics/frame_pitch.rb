# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The pitch a stretch of sound is heard at, in hertz, or nil where it has none: a noise, a drum,
    # or silence. One voice at a time: two notes sounding together have no one pitch.
    #
    #   FramePitch.hertz_of(frame, rate: 44_100, before: frame_before)   # => 440.2 for an A
    #
    # ### How it is found
    #
    # A note is one shape of wave played again and again, so the sound matches itself moved along by
    # one wave's length. The method is YIN (de Cheveigné and Kawahara, "YIN, a fundamental frequency
    # estimator for speech and music", 2002): for each lag, how far the newest half of the samples is
    # from the samples that lag earlier (the squared difference), each lag's figure divided by the
    # average of those before it so a lag of nought does not win. The first lag whose figure falls
    # under YIN_THRESHOLD is one wave; the lowest point there, read between samples on the parabola
    # through it and its neighbours, is how long a wave is. Every whole number of waves matches too,
    # and taking the first that does is what keeps a note from reading an octave low.
    #
    # ### Whose pitch it is
    #
    # What is matched is the newest half of +samples+, so the pitch is that stretch's own. The
    # samples +before+ it are only room to look back into, for a wave longer than the rest of the
    # stretch: half of one of the console's frames holds two waves of a note down to about 120 Hz,
    # and a lower one reaches back into the frame before. So a note's first frame after silence has
    # its pitch, a new note is read on its own first frame, and a note too low to fit in its first
    # frame has none there.
    #
    # The squared differences come from the correlation of the samples with that half, made with
    # FastFourier, so a stretch costs three transforms and not a sum for every lag.
    module FramePitch
      # A lag's figure under this is a wave: the threshold the YIN paper finds works for music.
      YIN_THRESHOLD = 0.15

      # The highest figure a lag can have and still be a wave, where none gets under YIN_THRESHOLD,
      # or where a few waves of a high note line up better than one (#whole_wave): over it the sound
      # repeats too little to have a pitch.
      PITCHED_FIGURE_LIMIT = 0.35

      # The shortest wave looked for, in samples: two samples is the highest pitch a rate can carry.
      SHORTEST_LAG = 2

      # The most waves of a high note a lag found is taken to hold (#whole_wave).
      MOST_WAVES_IN_LAG = 8

      def self.hertz_of(samples, rate:, before: [])
        half = samples.size / 2
        newest_first = (before + samples).reverse
        lags = newest_first.size - half
        return if half <= SHORTEST_LAG + 2 || lags <= SHORTEST_LAG + 2

        mean = samples.sum.fdiv(samples.size)
        centred = newest_first.map { |sample| sample - mean }
        differences = squared_differences(centred, half, lags)
        return if differences.nil?

        lag = wave_lag(centred, half, differences)
        lag && rate / lag
      end

      # How far the first +half+ of +samples+ is from the samples each lag later, for each of +lags+
      # lags from nought, or nil for a stretch of silence.
      def self.squared_differences(samples, half, lags)
        squares = samples.map { |sample| sample * sample }
        first_energy = squares.first(half).sum
        return if first_energy <= 0

        running = [0.0]
        squares.each { |square| running << (running.last + square) }
        correlation = correlation_with_first_half(samples, half)
        Array.new(lags) do |lag|
          first_energy + (running[lag + half] - running[lag]) - (2 * correlation[lag])
        end
      end

      # For each lag, the first +half+ samples times the samples that lag later, added up: the
      # transform of the samples times the conjugate transform of their first half, turned back.
      def self.correlation_with_first_half(samples, half)
        size = 1 << Math.log2(samples.size + half).ceil
        order = FastFourier.order(size)
        whole = FastFourier.transform(samples + Array.new(size - samples.size, 0.0), order)
        first = FastFourier.transform(samples.first(half) + Array.new(size - half, 0.0), order)
        real = Array.new(size) { |at| (whole[0][at] * first[0][at]) + (whole[1][at] * first[1][at]) }
        imaginary = Array.new(size) { |at| (whole[1][at] * first[0][at]) - (whole[0][at] * first[1][at]) }
        FastFourier.transform(real, order, imaginary, inverse: true).first
      end

      # Each lag's squared difference divided by the average of those for the lags from 1 to it.
      def self.normalized(differences)
        total = 0.0
        differences.each_with_index.map do |difference, lag|
          next 1.0 if lag.zero?

          total += difference
          total.positive? ? difference * lag / total : 1.0
        end
      end

      # The length of one wave, in samples and between them, or nil where nothing repeats.
      def self.wave_lag(samples, half, differences)
        figures = normalized(differences)
        lag = (SHORTEST_LAG...(figures.size - 1)).find { |at| figures[at] < YIN_THRESHOLD }
        if lag
          lag = lowest_near(figures, lag)
        else
          lag = (SHORTEST_LAG...(figures.size - 1)).min_by { |at| figures[at] }
          return if lag.nil? || figures[lag] >= PITCHED_FIGURE_LIMIT
        end
        whole_wave(samples, half, differences, between(figures, lag))
      end

      # The lag a wave really is, where +lag+ may be two to MOST_WAVES_IN_LAG of them.
      #
      # ### Why a high note can read low
      #
      # A wave of a high note is not a whole number of samples long: at 44,100 a second a note of
      # 6000 Hz is seven and a third. Moved along by seven or eight samples its edges miss by a third
      # of a sample each wave, which is a large share of so short a wave, and no whole lag near it
      # matches; three waves are twenty-two samples, and do. So the lag found is divided by each
      # number of waves from the most down, and the samples are matched moved along by that much,
      # read between samples (#figure_between_samples): the most waves whose one wave still matches
      # is the note.
      def self.whole_wave(samples, half, differences, lag)
        MOST_WAVES_IN_LAG.downto(2) do |waves|
          wave = lag / waves
          next if wave < SHORTEST_LAG

          return wave if figure_between_samples(samples, half, differences, wave) < PITCHED_FIGURE_LIMIT
        end
        lag
      end

      # The figure of a lag that need not be a whole number of samples: the first +half+ of
      # +samples+ against the samples that far later, each read on the straight line between the two
      # it falls between, divided by the average squared difference of the whole lags up to it.
      def self.figure_between_samples(samples, half, differences, lag)
        whole = lag.floor
        share = lag - whole
        difference = (0...half).sum do |at|
          later = samples[at + whole] + ((samples[at + whole + 1] - samples[at + whole]) * share)
          (samples[at] - later)**2
        end
        average = differences[1..whole].sum / whole
        average.positive? ? difference / average : 1.0
      end

      # The lag at the bottom of the dip +lag+ is in.
      def self.lowest_near(figures, lag)
        lag -= 1 while lag > 1 && figures[lag - 1] < figures[lag]
        lag += 1 while lag + 1 < figures.size - 1 && figures[lag + 1] < figures[lag]
        lag
      end

      # The lowest point of the parabola through +lag+ and its two neighbours.
      def self.between(figures, lag)
        before, at, after = figures[lag - 1], figures[lag], figures[lag + 1]
        bend = before - (2 * at) + after
        return lag.to_f if bend <= 0

        lag + ((before - after) / (2 * bend))
      end
      private_class_method :squared_differences, :correlation_with_first_half, :normalized, :wave_lag, :whole_wave,
                           :figure_between_samples, :lowest_near, :between
    end
  end
end
