# frozen_string_literal: true

module VBlank
  module Audio
    # A NOTE'S SHAPE AS THE SUPER NINTENDO'S SOUND CHIP KEEPS IT: the three bytes of a voice's
    # envelope registers, for an instrument whose settings came out of a Super Nintendo game.
    #
    #   instrument :horn, from: "horn.wav", envelope: VBlank::Audio::SNESEnvelope.new(adsr1: 0x8E, adsr2: 0xE0)
    #
    # WHAT THE CHIP DOES WITH THEM. The sound chip (the S-DSP) moves each voice's loudness by
    # itself, 32,000 times a second, and a game only sets how:
    #
    #   adsr1   its top bit chooses: set, the note is shaped by these two bytes; clear, by +gain+.
    #           The low four bits are how fast the note climbs (attack) and the three above them
    #           how fast it then falls (decay).
    #   adsr2   the top three bits are how far it falls, in eighths (the sustain level), and the
    #           low five how fast it goes on falling from there (the sustain rate; nought holds).
    #   gain    top bit clear, the level itself, held. Top bit set, one of four ways to move:
    #           down in even steps, down by a part of itself, up in even steps, or up in even
    #           steps that shorten near the top.
    #
    # A Super Nintendo build writes the three bytes to the chip as they are, so the note is shaped
    # exactly as in the game they came from. Audio::Envelope cannot hold them: its four numbers
    # are another sound engine's, and nothing in it means "up in steps that shorten".
    #
    # EVERY OTHER BUILD PLAYS THE NEAREST ORDINARY ENVELOPE (#closest_envelope), worked out once
    # as the game is built, by playing the chip's own arithmetic forward and fitting an
    # Audio::Envelope to the levels it reaches. So the game sounds much the same everywhere, and
    # what it can tell of a note (how long its voice is held) is the same on every build, the
    # Super Nintendo's included: only what is heard there is the chip's.
    SNESEnvelope = Data.define(:adsr1, :adsr2, :gain)

    class SNESEnvelope
      # How many of the chip's samples each of its 32 rates waits between steps, by rate; nought
      # never steps (fullsnes, "ADSR/Gain (and Noise) Rates"; the same table is counter_rates in
      # bsnes's SPC_DSP.cpp).
      RATE_SAMPLES = [nil, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80, 64, 48, 40,
                      32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1].freeze

      SAMPLE_RATE = 32_000 # Samples a second the chip plays, and moves a level at
      TOP = 0x7FF          # The highest a voice's level goes
      ADSR_ON = 0x80       # ADSR1's bit that chooses the two ADSR bytes over GAIN
      BENDS_AT = 0x600     # Where GAIN's bent climb shortens its steps

      # Which part of an ADSR note a voice is in.
      ATTACK = :attack
      DECAY = :decay
      SUSTAIN = :sustain

      # Where the search for the nearest envelope stops following the chip, in frames. The slowest
      # sustain rate takes longer than this to die away; what it has done by here is what is fitted.
      MOST_FRAMES = 4096

      # The chip's level at the end of each frame from key-on (+by_frame+, out of Envelope::FULL),
      # and whether it had stopped moving by the last of them.
      Levels = Data.define(:by_frame, :settled)

      # One step of the chip's arithmetic: the level it would move to, which rate it waits at,
      # and the part of the note the voice is in after it.
      Step = Data.define(:level, :rate, :phase)

      def initialize(adsr1: 0, adsr2: 0, gain: 0)
        { adsr1: adsr1, adsr2: adsr2, gain: gain }.each do |name, value|
          next if value.is_a?(Integer) && value.between?(0, 255)

          raise ArgumentError, "An SNESEnvelope has #{name}: #{value.inspect}. Each of the three is a whole number " \
                               "from 0 to 255, as the Super Nintendo's sound chip keeps them."
        end
        super
      end

      # WHAT AN AUTHOR WROTE AS AN `envelope:`, WHERE IT MAY BE THE CHIP'S BYTES, read two ways. The
      # shape every build but the Super Nintendo's plays: the nearest Envelope for an SNESEnvelope,
      # and for anything else what Envelope.of makes of it (+where+ names what it was written on,
      # for a message). And the bytes themselves, for the Super Nintendo's build: +said+ when it
      # is an SNESEnvelope, or nil.
      def self.nearest_shape(said, where) = said.is_a?(SNESEnvelope) ? said.closest_envelope : Envelope.of(said, where)
      def self.chip_envelope_of(said) = (said if said.is_a?(SNESEnvelope))

      # Whether the two ADSR bytes shape the note. When not, GAIN does.
      def adsr? = adsr1.anybits?(ADSR_ON)

      # THE ORDINARY ENVELOPE NEAREST WHAT THE CHIP DOES, for every build but the Super Nintendo's.
      #
      # An Audio::Envelope climbs in even steps to full, falls by a multiply to a level, and holds.
      # So the chip's levels are cut at their highest: the climb to it gives the attack, the level
      # the chip ends at the sustain, and the fall between the decay, each the number whose
      # levels come nearest the chip's, frame for frame. The release is nought, since a key-off
      # takes the chip's level down 8 a sample, which is over inside a frame; an envelope with a
      # release of nought and any shape still slides to nothing across that frame.
      #
      # What does not carry over: an envelope always climbs to full, so a level GAIN holds below
      # the top is reached a frame late, after a frame at full. A note whose level never leaves
      # nothing (a GAIN that only falls, since a key-on starts the level at nothing) is silent.
      def closest_envelope
        levels = chip_levels
        peak = levels.by_frame.max
        return Envelope.new(attack: 0, decay: 0, sustain: Envelope::MOST, release: 0) if peak.zero?

        climb = levels.by_frame.index(peak) + 1
        floor = levels.settled ? levels.by_frame.last : 0
        Envelope.new(attack: closest_attack(levels.by_frame.first(climb), peak),
                     decay: closest_decay(levels.by_frame.drop(climb), floor), sustain: floor, release: 0)
      end

      # THE CHIP'S LEVEL, FRAME BY FRAME FROM KEY-ON, as far as it moves or MOST_FRAMES. The chip
      # works a step out on every sample and takes it only when its rate's wait is up, so this
      # goes from step to step, not sample to sample. Which sample a wait ends on depends on a
      # counter the whole chip shares; here it counts from the key-on, which is at most one wait out.
      def chip_levels
        level = 0
        phase = ATTACK
        now = 0 # samples since key-on
        frames = []
        settled = false
        until frames.size >= MOST_FRAMES
          step = chip_step(level, phase)
          wait = RATE_SAMPLES[step.rate]
          if step.phase != phase
            # The part of the note changes on the next sample, whether or not that step is taken.
            now += 1
            phase = step.phase
            record_frames(frames, level, now)
            level = step.level if wait && (now % wait).zero?
            next
          end
          break settled = true if wait.nil? || step.level == level

          now = ((now / wait) + 1) * wait
          record_frames(frames, level, now)
          level = step.level
        end
        frames << heard(level) if settled
        Levels.new(by_frame: frames.first(MOST_FRAMES), settled: settled)
      end

      private

      # +level+ for every frame that ends before sample +now+ and is not in +frames+ yet.
      def record_frames(frames, level, now)
        frames << heard(level) while frames.size < MOST_FRAMES && ((frames.size + 1) * SAMPLE_RATE / Envelope::FRAME_RATE) < now
      end

      # A level of the chip's as one of an Envelope's: the seven bits of it the chip itself shows
      # (its ENVX register), so the highest level each mode reaches reads as full.
      def heard(level) = ((level >> 4) * Envelope::FULL / 127.0).round

      # What the chip works out for a voice at +level+ in +phase+ (bsnes's SPC_DSP::run_envelope,
      # and fullsnes, "SNES APU DSP ADSR/Gain Envelope").
      def chip_step(level, phase)
        return gain_step(level, phase) unless adsr?

        if phase == ATTACK
          rate = ((adsr1 & 0x0F) * 2) + 1
          moved = level + (rate < 31 ? 0x20 : 0x400)
        else
          moved = fallen_by_part(level)
          rate = phase == DECAY ? ((adsr1 >> 3) & 0x0E) + 0x10 : adsr2 & 0x1F
        end
        # The decay ends once the level's top three bits are the sustain level's.
        phase = SUSTAIN if phase == DECAY && (moved >> 8) == (adsr2 >> 5)
        phase = DECAY if phase == ATTACK && moved > TOP
        Step.new(level: moved.clamp(0, TOP), rate: rate, phase: phase)
      end

      def gain_step(level, phase)
        mode = gain >> 5
        return Step.new(level: gain * 0x10, rate: 31, phase: phase) if mode < 4 # the level itself

        moved = case mode
                when 4 then level - 0x20
                when 5 then fallen_by_part(level)
                when 6 then level + 0x20
                # The chip asks whether the level it last worked out is past the bend, which is this
                # level and a whole step.
                else level + (level + 0x20 >= BENDS_AT ? 0x08 : 0x20)
                end
        Step.new(level: moved.clamp(0, TOP), rate: gain & 0x1F, phase: phase)
      end

      # A fall by a 256th of the level, and one more.
      def fallen_by_part(level) = level - 1 - ((level - 1) >> 8)

      # The attack whose even climb to full comes nearest +climb+, the chip's levels up to its
      # highest (+peak+), which an envelope's full stands for.
      def closest_attack(climb, peak)
        wanted = climb.map { |level| level * Envelope::FULL / peak.to_f }
        levels = ->(attack) { (1..wanted.size).map { |frame| [attack * frame, Envelope::FULL].min } }
        nearest_number(1, wanted, levels)
      end

      # The decay whose fall from full to +floor+ comes nearest +fall+, the chip's levels after its
      # highest. A chip that holds at its highest, or drops straight to where it holds, has no
      # fall to fit: nought takes an envelope to its sustain in one frame.
      def closest_decay(fall, floor)
        return 0 if fall.empty?

        levels = lambda do |decay|
          level = Envelope::FULL
          fall.map { level = [(level * decay) >> Envelope::SCALE, floor].max }
        end
        nearest_number(0, fall, levels)
      end

      # The number from +least+ to Envelope::MOST whose +levels+ come nearest +wanted+, by the sum
      # of the squares of what each frame is out. A bigger number gives levels no lower anywhere,
      # so the first number whose levels are not under +wanted+ in all is found by halving, and it
      # or the one below is the nearest.
      def nearest_number(least, wanted, levels)
        over = (least..Envelope::MOST).bsearch { |number| levels.call(number).sum >= wanted.sum } || Envelope::MOST
        [over - 1, over].select { |number| number >= least }.min_by do |number|
          levels.call(number).zip(wanted).sum { |level, want| (level - want)**2 }
        end
      end
    end
  end
end
