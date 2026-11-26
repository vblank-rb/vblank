# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about sound effects on the tune's tempo beside a song with no one tempo:
        #
        # > The sound effects have `on_tune_tempo: true`, and the song :tune has no single tempo. The
        # > effects count at the tempo of the song that plays, so they stop while :tune plays. To fix
        # > this, make :tune a Score with one number for `tempo:`. Or remove `on_tune_tempo:`.
        #
        # A driver that keeps one tempo count for its music and its effects moves the effects on at the
        # playing song's tempo. A song made with a `song` block, or a Score whose tempo changes, has no
        # one rate to count at, so an effect started while it plays would sound its first note and wait
        # there. The build stops and names the song.
        #
        #--
        # IR::Tunes.tune_tempo_step is nought for such a song, the same as for no song at all.
        #++
        class EffectTuneTempoUnknown
          NAME = :effect_tune_tempo_unknown
          PLAIN_NAME = "sound effects on the tempo of a song that has none"

          def detect(program)
            return [] unless Tunes.effects_on_tune_tempo?(program)

            effects = Tunes.effects(program)
            Tunes.declared_songs(program).filter_map do |song|
              next if song.tick_rate || effects.include?(song.name)

              Finding.new(check: NAME, severity: :error, message: message(song.name), node: song)
            end
          end

          private

          def message(name)
            "The sound effects have `on_tune_tempo: true`, and the song #{name.inspect} has no single tempo. " \
              "The effects count at the tempo of the song that plays, so they stop while #{name.inspect} plays. " \
              "To fix this, make #{name.inspect} a Score with one number for `tempo:`. Or remove `on_tune_tempo:`."
          end
        end
      end
    end
  end
end
