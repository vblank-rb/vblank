# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The pitch a stretch of sound is heard at, in hertz, or nil where it has none: a noise, a drum,
    # or silence. One voice at a time: two notes sounding together have no one pitch.
    #
    #   FramePitch.hertz_of(samples, rate: 44_100)   # => 440.2 for an A
    #
    # ### How it is found
    #
    # A note is one shape of wave played again and again, so the sound matches itself moved along by
    # one wave's length. The method is YIN (de Cheveigné and Kawahara, "YIN, a fundamental frequency
    # estimator for speech and music", 2002): for each lag, how far the first half of the samples is
    # from the samples that lag later (the squared difference), each lag's figure divided by the
    # average of those before it so a lag of nought does not win. The first lag whose figure falls
    # under ONE_WAVE_BELOW is one wave; the lowest point there, read between samples on the parabola
    # through it and its neighbours, is how long a wave is. Every whole number of waves matches too,
    # and taking the first that does is what keeps a note from reading an octave low.
    #
    # The squared differences come from the correlation of the samples with their first half, made
    # with FastFourier, so a stretch costs three transforms and not a sum for every lag.
    #
    # A stretch must hold two waves of the lowest note it can find: two of the console's frames
    # hold two waves of a note down to about 60 Hz.
    module FramePitch
      # A lag's figure under this is a wave: the threshold the YIN paper finds works for music.
      ONE_WAVE_BELOW = 0.15

      # Where no lag gets under ONE_WAVE_BELOW, the lowest still counts as a wave if it is under
      # this; over it the sound repeats too little to have a pitch.
      PITCHED_BELOW = 0.35

      # The highest pitch looked for: above the top note of a piano, which is about 4200 Hz.
      HIGHEST_HZ = 5000

      def self.hertz_of(samples, rate:)
        half = samples.size / 2
        shortest = [(rate / HIGHEST_HZ).floor, 2].max
        return if half <= shortest + 2

        mean = samples.sum.fdiv(samples.size)
        centred = samples.map { |sample| sample - mean }
        differences = squared_differences(centred, half)
        return if differences.nil?

        lag = wave_lag(normalized(differences), shortest)
        lag && rate / lag
      end

      # How far the first +half+ of +samples+ is from the samples each lag later, for each lag from
      # nought to +half+ - 1, or nil for a stretch of silence.
      def self.squared_differences(samples, half)
        squares = samples.map { |sample| sample * sample }
        first_energy = squares.first(half).sum
        return if first_energy <= 0

        running = [0.0]
        squares.each { |square| running << (running.last + square) }
        correlation = correlation_with_first_half(samples, half)
        Array.new(half) do |lag|
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
      def self.wave_lag(figures, shortest)
        lag = (shortest...(figures.size - 1)).find { |at| figures[at] < ONE_WAVE_BELOW }
        if lag
          lag = lowest_near(figures, lag)
        else
          lag = (shortest...(figures.size - 1)).min_by { |at| figures[at] }
          return if lag.nil? || figures[lag] >= PITCHED_BELOW
        end
        between(figures, whole_wave(figures, lag, shortest))
      end

      # The lag a wave really is, where +lag+ may be two, three or four of them.
      #
      # ### Why a high note can read low
      #
      # A wave of a high note is not a whole number of samples long: at 44,100 a second a note of
      # 3520 Hz is twelve and a half. Moved along by twelve or thirteen samples its edges miss by half
      # a sample each wave, which is a large share of so short a wave, and its figure stays over
      # ONE_WAVE_BELOW; two waves are twenty-five samples, and match. So where a half, a third or a
      # quarter of the lag found also matches, though less well, that is the wave.
      def self.whole_wave(figures, lag, shortest)
        4.downto(2) do |parts|
          part = lag.fdiv(parts).round
          next if part < shortest

          near = lowest_near(figures, part)
          return near if figures[near] < PITCHED_BELOW && (near * parts - lag).abs <= parts
        end
        lag
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
                           :lowest_near, :between
    end
  end
end
