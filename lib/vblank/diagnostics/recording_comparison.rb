# frozen_string_literal: true

module VBlank
  module Diagnostics
    # How far apart two recordings may sound and still be heard as the same, each in decibels or hertz.
    # A game gives every one, each with its reason beside it in its test: none has a value assumed.
    #
    #   quiet_below_db         how far under a recording's loudest moment a moment is quiet: the quiet
    #                          moments are where the noise floor is read, and where loudness and tone
    #                          are not compared (40 is the usual: a sound 40 dB down is near silence)
    #   loudness_db_apart      how far apart the two may be in loudness at any moment, once their whole
    #                          loudness is matched: a sound too quiet, clipped or flattened
    #   mel_db_apart           how far apart their tone may be at any moment: the mel-spectrum distance
    #                          (below), a wrong note or a wrong instrument
    #   noise_floor_db_apart   how much louder the first's quiet may be than the second's: hiss and static
    #   rolloff_hz_apart       how much lower the first's high sounds may stop than the second's: muffling
    RecordingTolerances = Data.define(:quiet_below_db, :loudness_db_apart, :mel_db_apart, :noise_floor_db_apart,
                                      :rolloff_hz_apart) do
      def initialize(**given)
        given.each do |name, value|
          next if value.is_a?(Numeric) && !value.negative?

          raise ArgumentError, "`#{name}:` was #{value.inspect}. It must be a number, 0 or more."
        end
        super
      end
    end

    # One measure out by more than the game allows, between two recordings. +what+ is +:never_heard+,
    # +:loudness+, +:tone+, +:noise_floor+ or +:muffled+. +seconds+ and +frame+ say where the first
    # moment out begins, counted from each recording's first sound (+frame+ from 1, in the first
    # recording's frames); nil for a measure of the whole recording. +measured+ is the measure on each
    # there, the first recording's and then the second's (decibels or hertz; for +:tone+ the distance
    # itself, once), and +moments_over+ how many moments are out.
    RecordingDifference = Data.define(:what, :seconds, :frame, :measured, :moments_over)

    # What was measured of both, whether out or not, so a report shows the whole picture: +gain_db+ is
    # how much louder the second is than the first over its loud moments (what the first was raised by
    # before loudness and tone were compared), +seconds+ how long each is from its first sound,
    # +noise_floors_db+ each one's loudness over the second's quiet moments, +rolloffs_hz+ the
    # frequency each one's high sounds stop at on average, +dynamic_ranges_db+ how far each one's loud
    # moments are over its quiet ones, and +worst_mel_db+ the largest tone distance at any moment.
    RecordingMeasures = Data.define(:gain_db, :seconds, :noise_floors_db, :rolloffs_hz, :dynamic_ranges_db, :worst_mel_db,
                                    :moments_compared)

    # Two recordings held to each other as a person hears them: a port's sound beside a recording of the
    # original's, which need not be a cartridge (a .wav rendered from a computer game's own music data).
    # Not sample for sample: two recordings a player hears as the same pass, and a difference a player
    # would hear fails, naming which kind.
    #
    #   compared = RecordingComparison.between(ours, reference, quiet_below_db: 40, loudness_db_apart: 3,
    #                                          mel_db_apart: 6, noise_floor_db_apart: 12, rolloff_hz_apart: 1500)
    #   compared.alike?
    #   compared.differences    # every measure out, RecordingDifferences
    #   compared.measures       # every measure, out or not
    #
    # +first+ and +second+ are SoundRecordings, at any rate and any bit depth they were made at.
    #
    # How they are lined up and made comparable. Each is heard from its first sound (its first sample
    # over its quiet level), so a cartridge's silent start-up and a recording's lead-in drop away, and
    # compared for as long as the shorter lasts. Each is cut into moments two of the first recording's
    # frames long, one after another, and each moment's spectrum is taken (a Hann window and a fast
    # Fourier transform). Only the band both can carry is compared, up to half the lower of the two
    # rates, which is what reading both at the lower rate would keep. The first is raised or lowered so
    # its loud moments are as loud as the second's in all, the gain the report gives.
    #
    # What is measured, each the standard way:
    #
    # - LOUDNESS: each moment's power in decibels, the envelope a too-quiet or clipped sound shows in.
    # - TONE: the mel-spectrum distance. The band is split into MEL_BANDS bands spaced as the ear hears
    #   pitch (the mel scale, 2595 log10(1 + f/700)), each moment's power in each band taken in
    #   decibels, and the distance is the root mean square of the two recordings' differences over the
    #   bands, in decibels. A band quieter than the moment's loudest band by more than +quiet_below_db+
    #   is held at that level on both sides, so near-silence in one band does not swamp the rest.
    # - Noise floor: the power of each over the moments the second is quiet in, in decibels below full
    #   scale; the first's may be louder than the second's by +noise_floor_db_apart+. Digital silence
    #   is read as SILENCE_DB.
    # - MUFFLING: the rolloff, the frequency under which ROLLOFF_SHARE of a moment's power lies; the
    #   first's may be lower than the second's by +rolloff_hz_apart+ on average over the loud moments.
    #
    # These are the measures a full-reference comparison such as PEAQ (ITU-R BS.1387) or ViSQOL rests
    # on, without their model of the ear: a game sets each tolerance from what it hears.
    class RecordingComparison
      # The bands the tone is compared in, and the lowest frequency they start from: below it a
      # moment two frames long holds less than a wave.
      MEL_BANDS = 40
      MEL_LOWEST_HZ = 60

      # The share of a moment's power under its rolloff frequency. 0.85 is the other usual choice, and
      # on a note it lands on the fundamental or the next harmonic, where cutting the top moves nothing:
      # the fundamental of a square wave holds over eight tenths of its power.
      ROLLOFF_SHARE = 0.95

      # The level digital silence is read at, in decibels below full scale: sixteen bits reach 96 down.
      SILENCE_DB = -120.0

      # A moment is this many of the first recording's frames long.
      FRAMES_A_MOMENT = 2

      def self.between(first, second, **tolerances)
        new(first, second, RecordingTolerances.new(**tolerances))
      end

      attr_reader :differences, :measures

      def initialize(first, second, tolerances)
        @tolerances = tolerances
        @frame_seconds = first.frame_seconds
        @moment_seconds = FRAMES_A_MOMENT * @frame_seconds
        heard = [first, second].map { |recording| from_first_sound(recording) }
        @differences = []
        if heard.any?(&:nil?)
          @differences << RecordingDifference.new(what: :never_heard, seconds: nil, frame: nil,
                                                  measured: heard.map { |samples| !samples.nil? }, moments_over: nil)
          return
        end
        compare(first, second, heard)
      end

      def alike? = @differences.empty?

      private

      # A recording's samples from its first sound on, as a share of full scale, or nil where it is
      # never over its quiet level.
      def from_first_sound(recording)
        loudest = recording.samples.map(&:abs).max.to_i
        return if loudest.zero?

        quiet = loudest * (10**(-@tolerances.quiet_below_db / 20.0))
        start = recording.samples.index { |sample| sample.abs > quiet }
        recording.samples.drop(start).map { |sample| sample / 32_768.0 }
      end

      def compare(first, second, heard)
        top_hz = [first.rate, second.rate].min / 2.0
        seconds = heard.zip([first, second]).map { |samples, recording| samples.size.fdiv(recording.rate) }
        count = (seconds.min / @moment_seconds).floor
        spectra = heard.zip([first, second]).map do |samples, recording|
          MomentSpectra.new(samples, recording.rate, @moment_seconds, top_hz).take(count)
        end
        measure(*spectra, seconds, count)
      end

      def measure(ours, theirs, seconds, count)
        theirs_loudest = theirs.map(&:level_db).max
        loud = (0...count).select do |at|
          theirs[at].level_db > theirs_loudest - @tolerances.quiet_below_db ||
            ours[at].level_db > ours.map(&:level_db).max - @tolerances.quiet_below_db
        end
        quiet = (0...count).reject { |at| theirs[at].level_db > theirs_loudest - @tolerances.quiet_below_db }
        gain = gain_db(ours, theirs, loud)
        mel = loud.to_h { |at| [at, mel_distance(ours[at], theirs[at], gain)] }
        check_loudness(ours, theirs, loud, gain)
        check_tone(mel)
        floors = check_noise_floor(ours, theirs, quiet, gain)
        rolloffs = check_rolloff(ours, theirs, loud)
        @measures = RecordingMeasures.new(gain_db: gain, seconds: seconds, noise_floors_db: floors, rolloffs_hz: rolloffs,
                                          dynamic_ranges_db: [ours, theirs].map { |side| dynamic_range(side) },
                                          worst_mel_db: mel.values.max, moments_compared: count)
      end

      # How much louder the second's loud moments are than the first's, in all.
      def gain_db(ours, theirs, loud)
        return 0.0 if loud.empty?

        [theirs, ours].map { |side| decibels(loud.sum { |at| side[at].power } / loud.size) }.reduce(:-)
      end

      def check_loudness(ours, theirs, loud, gain)
        over = loud.select { |at| (ours[at].level_db + gain - theirs[at].level_db).abs > @tolerances.loudness_db_apart }
        add(:loudness, over) { |at| [ours[at].level_db + gain, theirs[at].level_db] }
      end

      def check_tone(mel)
        over = mel.select { |_, distance| distance > @tolerances.mel_db_apart }.keys
        add(:tone, over) { |at| [mel[at]] }
      end

      # The two noise floors over the second's quiet moments, or nil where it has none.
      def check_noise_floor(ours, theirs, quiet, gain)
        return if quiet.empty?

        floors = [ours, theirs].zip([gain, 0]).map { |side, raised| decibels(quiet.sum { |at| side[at].power } / quiet.size) + raised }
        if floors[0] - floors[1] > @tolerances.noise_floor_db_apart
          at = quiet.find { |moment| ours[moment].level_db + gain - theirs[moment].level_db > @tolerances.noise_floor_db_apart }
          @differences << RecordingDifference.new(what: :noise_floor, seconds: at && moment_start(at), frame: at && moment_frame(at),
                                                  measured: floors, moments_over: nil)
        end
        floors
      end

      # The two rolloffs averaged over the loud moments, or nil where there are none.
      def check_rolloff(ours, theirs, loud)
        return if loud.empty?

        averages = [ours, theirs].map { |side| loud.sum { |at| side[at].rolloff_hz } / loud.size }
        if averages[1] - averages[0] > @tolerances.rolloff_hz_apart
          over = loud.select { |at| theirs[at].rolloff_hz - ours[at].rolloff_hz > @tolerances.rolloff_hz_apart }
          at = over.first
          @differences << RecordingDifference.new(what: :muffled, seconds: at && moment_start(at), frame: at && moment_frame(at),
                                                  measured: averages, moments_over: over.size)
        end
        averages
      end

      def add(what, over)
        return if over.empty?

        at = over.first
        @differences << RecordingDifference.new(what: what, seconds: moment_start(at), frame: moment_frame(at),
                                                measured: yield(at), moments_over: over.size)
      end

      # The distance between two moments' mel spectra, the first raised by +gain+, in decibels.
      def mel_distance(ours, theirs, gain)
        floor = [ours.bands_db.max + gain, theirs.bands_db.max].max - @tolerances.quiet_below_db
        squares = ours.bands_db.zip(theirs.bands_db).sum do |one, other|
          ([one + gain, floor].max - [other, floor].max)**2
        end
        Math.sqrt(squares / MEL_BANDS)
      end

      # How far a recording's loud moments are over its quiet ones: the twentieth loudest share of
      # its moments against the twentieth quietest.
      def dynamic_range(side)
        levels = side.map(&:level_db).sort
        return 0.0 if levels.empty?

        levels[(levels.size * 0.95).floor.clamp(0, levels.size - 1)] - levels[(levels.size * 0.05).floor]
      end

      def moment_start(at) = at * @moment_seconds
      def moment_frame(at) = (at * FRAMES_A_MOMENT) + 1

      def decibels(power) = power.positive? ? [10 * Math.log10(power), SILENCE_DB].max : SILENCE_DB

      # Each moment of one recording, heard: its power in all, in each mel band and in decibels, and its
      # rolloff, over the band both recordings carry (up to +top_hz+). A moment's power is the mean
      # square of its samples as a share of full scale, so a moment of a full-scale wave is near 0 dB
      # whatever the rate it was made at.
      class MomentSpectra
        Moment = Data.define(:power, :level_db, :bands_db, :rolloff_hz)

        def initialize(samples, rate, moment_seconds, top_hz)
          @samples = samples
          @length = (moment_seconds * rate).round
          @size = 1 << Math.log2(@length).ceil
          @rate = rate
          @top_hz = top_hz
          @hann = Array.new(@length) { |at| 0.5 - (0.5 * Math.cos(2 * Math::PI * at / (@length - 1))) }
          @hann_power = @hann.sum { |weight| weight * weight }
          @bins = (1..(@size / 2)).select { |bin| bin_hz(bin) <= top_hz }
          @band_weights = band_weights
          @order = FastFourier.order(@size)
        end

        # The first +count+ moments, one after another.
        def take(count)
          Array.new(count) { |at| moment(@samples[at * @length, @length] || []) }
        end

        private

        def bin_hz(bin) = bin * @rate.fdiv(@size)

        def moment(samples)
          samples += Array.new(@length - samples.size, 0.0)
          powers = power_by_bin(samples)
          total = @bins.sum { |bin| powers[bin] }
          bands = @band_weights.map { |weights| weights.sum { |bin, weight| powers[bin] * weight } }
          Moment.new(power: total, level_db: decibels(total), bands_db: bands.map { |power| decibels(power) },
                     rolloff_hz: rolloff(powers, total))
        end

        # Each bin's power, scaled so the bins of the band add up to the moment's mean square power.
        def power_by_bin(samples)
          real = Array.new(@size, 0.0)
          samples.each_with_index { |sample, at| real[at] = sample * @hann[at] }
          real, imaginary = FastFourier.transform(real, @order)
          scale = 2.0 / (@hann_power * @size)
          Array.new((@size / 2) + 1) { |bin| ((real[bin]**2) + (imaginary[bin]**2)) * scale }
        end

        def rolloff(powers, total)
          return 0.0 unless total.positive?

          sum = 0.0
          @bins.each do |bin|
            sum += powers[bin]
            return bin_hz(bin) if sum >= ROLLOFF_SHARE * total
          end
          bin_hz(@bins.last)
        end

        # For each mel band, the bins in it and each one's weight: triangles spaced evenly in mels
        # from MEL_LOWEST_HZ to the top of the band, each rising from its left neighbour's centre to its
        # own and falling to its right neighbour's.
        def band_weights
          edges = Array.new(MEL_BANDS + 2) do |at|
            low = mel(MEL_LOWEST_HZ)
            hz_of_mel(low + ((mel(@top_hz) - low) * at / (MEL_BANDS + 1)))
          end
          Array.new(MEL_BANDS) do |band|
            left, centre, right = edges[band, 3]
            @bins.filter_map do |bin|
              hz = bin_hz(bin)
              weight = if hz.between?(left, centre) then (hz - left) / (centre - left)
                       elsif hz > centre && hz <= right then (right - hz) / (right - centre)
                       end
              [bin, weight] if weight&.positive?
            end
          end
        end

        def mel(hz) = 2595 * Math.log10(1 + (hz / 700.0))
        def hz_of_mel(mels) = 700 * ((10**(mels / 2595.0)) - 1)

        def decibels(power) = power.positive? ? [10 * Math.log10(power), SILENCE_DB].max : SILENCE_DB
      end
      private_constant :MomentSpectra

      # The fast fourier transform, the radix-2 one: +real+ (a power of two long) as the frequencies it
      # holds, the real and the imaginary part of each. Cooley and Tukey's, done in place over the
      # numbers put in +order+ (FastFourier.order: each place's number with its bits reversed).
      module FastFourier
        def self.transform(real, order)
          size = real.size
          real = order.map { |at| real[at] }
          imaginary = Array.new(size, 0.0)
          span = 2
          while span <= size
            half = span / 2
            step = -2 * Math::PI / span
            (0...half).each do |turn|
              cos = Math.cos(step * turn)
              sin = Math.sin(step * turn)
              (turn...size).step(span) do |at|
                other = at + half
                re = (real[other] * cos) - (imaginary[other] * sin)
                im = (real[other] * sin) + (imaginary[other] * cos)
                real[other] = real[at] - re
                imaginary[other] = imaginary[at] - im
                real[at] += re
                imaginary[at] += im
              end
            end
            span *= 2
          end
          [real, imaginary]
        end

        # The places 0 to +size+ - 1, each with its bits reversed: the order the transform reads its
        # numbers in.
        def self.order(size)
          bits = Math.log2(size).to_i
          Array.new(size) { |at| at.to_s(2).rjust(bits, "0").reverse.to_i(2) }
        end
      end
      private_constant :FastFourier
    end
  end
end
