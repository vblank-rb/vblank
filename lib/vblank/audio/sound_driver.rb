# frozen_string_literal: true

module VBlank
  module Audio
    # How the original's sound driver keeps time, described once for the whole game
    # (`sound_driver ...` in a game). A cartridge's sound driver is a small program of its own, and the
    # timing habits it had decide which beat each effect and song lands on. A port reads them from its
    # original, by measuring it in the emulator or by reading its sound code, and every build then
    # plays its effects on the beats the original did.
    #
    # Every setting left out keeps VBlank's own way, so a game that names none sounds as it always
    # did.
    #
    # - +interrupts_per_second+: how often the driver wakes, from a timer of the sound chip. On each
    #   wake it adds its tempo to a count, and a tick is where the count comes round, so the effects'
    #   notes fall on the wakes (Audio::Score's +interrupts_per_second+). Naming it puts every sound
    #   effect on the timer.
    # - +effects_tempo+: `:own`, each effect at its own Score's tempo, or `:song`, every effect at the
    #   tempo of the song playing, and not at all while none plays (Score's +on_tune_tempo+).
    # - +tick_count_at_song_start+: where a song's start sets the count, a share of a tick from 0 up to 1
    #   (Score's +tick_count_at_song_start+).
    # - +effects_start+: `:at_once`, an effect's first note on the first wake after it is asked for, or
    #   `:on_next_tick`, on the first wake whose count comes round, as a driver that keys its effects
    #   only on a tick does.
    # - +silent_music_stops_ticks+: while the music is at volume 0, from `music_volume 0` or a fade out
    #   that has reached silence, the driver skips its tick: the count stands still, and the effects
    #   wait, until the music is heard again.
    # - +cuts_own_notes+ and +note_fade_out+: as the Score settings of the same names, for every effect,
    #   and for every Score's notes.
    #
    # A request can also say at which screen row it is sent (`sfx.play :step, sent_after_rows: 32`),
    # counted from the start of the console's vertical blank, which is where the pass asking for it
    # begins. The driver picks it up on its next wake, part way through the frame (IR::Tunes.row_share).
    SoundDriver = Data.define(:interrupts_per_second, :effects_tempo, :tick_count_at_song_start, :effects_start,
                              :silent_music_stops_ticks, :cuts_own_notes, :note_fade_out)

    class SoundDriver
      EFFECTS_TEMPOS = %i[own song].freeze
      EFFECT_STARTS = %i[at_once on_next_tick].freeze

      def initialize(interrupts_per_second: nil, effects_tempo: :own, tick_count_at_song_start: nil,
                     effects_start: :at_once, silent_music_stops_ticks: false, cuts_own_notes: false, note_fade_out: nil)
        super
        refuse_unknown_choice!(:effects_tempo, effects_tempo, EFFECTS_TEMPOS)
        refuse_unknown_choice!(:effects_start, effects_start, EFFECT_STARTS)
        refuse_not_true_or_false!(:silent_music_stops_ticks, silent_music_stops_ticks)
        refuse_not_true_or_false!(:cuts_own_notes, cuts_own_notes)
        refuse_settings_without_interrupts!
      end

      # The settings of a sound effect's Score under this description: on the driver's timer where it
      # wakes on one, with the tempo and the count the driver keeps, cutting its own notes as the
      # driver does, and fading its notes as the driver does unless the Score gives its own fade.
      def effect_settings(score)
        settings = { cuts_own_notes: cuts_own_notes || score.cuts_own_notes, note_fade_out: score.note_fade_out || note_fade_out }
        return settings unless interrupts_per_second

        settings.merge(on_timer: true, interrupts_per_second: interrupts_per_second,
                       on_tune_tempo: effects_tempo == :song || score.on_tune_tempo,
                       tick_count_at_song_start: tick_count_at_song_start || score.tick_count_at_song_start)
      end

      # ...and of a song's: only how its notes fade.
      def song_settings(score) = { note_fade_out: score.note_fade_out || note_fade_out }

      # Whether the driver keys an effect only on a tick (+effects_start+ `:on_next_tick`).
      def starts_on_tick? = effects_start == :on_next_tick

      private

      def refuse_unknown_choice!(word, given, choices)
        return if choices.include?(given)

        raise ArgumentError, "The sound driver has `#{word}: #{given.inspect}`. It must be one of " \
                             "#{choices.map(&:inspect).join(' or ')}."
      end

      def refuse_not_true_or_false!(word, given)
        return if [true, false].include?(given)

        raise ArgumentError, "The sound driver has `#{word}: #{given.inspect}`. It must be true or false."
      end

      # What the driver does on its wakes needs the wakes.
      def refuse_settings_without_interrupts!
        return if interrupts_per_second

        named = { effects_tempo: effects_tempo != :own, tick_count_at_song_start: !tick_count_at_song_start.nil?,
                  effects_start: effects_start != :at_once, silent_music_stops_ticks: silent_music_stops_ticks }
        word = named.find { |_, given| given }&.first or return
        raise ArgumentError, "The sound driver has `#{word}:` and not `interrupts_per_second:`. It is about the " \
                             "driver's wakes. Add `interrupts_per_second:`, or remove `#{word}:`."
      end
    end
  end
end
