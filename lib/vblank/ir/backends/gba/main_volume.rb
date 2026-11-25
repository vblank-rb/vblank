# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # The main volume a game names (`enable_sound main_volume:`, Program#main_volume, in 127ths), AS
        # the Advance's registers hold it. The Advance has no one main volume: it has three settings, and
        # each takes the nearest it can.
        #
        # The Game Boy voices (the squares, the wave and the noise) are turned down twice before they
        # reach the speakers: by the level in SOUNDCNT_L's low byte, which plays them at (level + 1)
        # eighths (Backends::GameBoySound), and then by SOUNDCNT_H's bits 0 and 1, which keep a quarter
        # (0), a half (1) or all (2) of that (GBATEK, "GBA Sound Control Registers"). So they can be
        # played at any of a few dozen 32nds, from 1/32 to 32/32, and the pair whose product is nearest
        # the main volume is the one written, at the whole share where two are as near.
        #
        # The recordings are channel A's, which SOUNDCNT_H's bit 2 plays at half (0) or all (1), and
        # nothing between: the nearer of the two is written.
        #
        # A main volume of nothing is the sound left switched off (SOUNDCNT_X's bit 7), since the
        # quietest of the steps above is still heard.
        #
        # A game that names none is at the loudest of all three: level 7, the whole share and channel A
        # at all, the registers as they were before a game could name one.
        module MainVolume
          # SOUNDCNT_H's bits 0 and 1 for the Game Boy voices' share, by the quarters of them each keeps.
          SHARE_BITS = { 4 => 2, 2 => 1, 1 => 0 }.freeze

          # What the three settings are for one main volume: the level both speakers are set to, the
          # Game Boy voices' share (SOUNDCNT_H's bits 0 and 1), whether channel A plays at all rather
          # than half, and whether the sound is switched on.
          Settings = Data.define(:speaker_level, :share_bits, :recordings_full, :powered)

          LOUDEST = Settings.new(speaker_level: GameBoySound::SPEAKER_LEVEL_LOUDEST, share_bits: SHARE_BITS.fetch(4),
                                 recordings_full: true, powered: true)

          module_function

          def settings(main_volume)
            return LOUDEST if main_volume.nil?

            loudest = VBlank::Audio::Sound::MAIN_VOLUME_LOUDEST
            return LOUDEST.with(powered: false) if main_volume.zero?

            # Each pair's 32nds against the main volume's 127ths, both made 127 * 32nds to compare.
            level, quarters = SHARE_BITS.keys.flat_map do |share|
              (0..GameBoySound::SPEAKER_LEVEL_LOUDEST).map { |each_level| [each_level, share] }
            end.min_by { |each_level, share| ((each_level + 1) * share * loudest - (main_volume * 32)).abs }
            Settings.new(speaker_level: level, share_bits: SHARE_BITS.fetch(quarters),
                         recordings_full: main_volume * 4 >= loudest * 3, powered: true)
          end
        end
      end
    end
  end
end
