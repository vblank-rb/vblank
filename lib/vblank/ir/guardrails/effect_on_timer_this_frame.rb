# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error about a sound effect on a timer asked to start on the frame it is asked for:
        #
        # > Sound effect list :<list> is played with `this_frame: true`, and its sound effects have
        # > `on_timer: true`. An effect on the timer starts when the next frame's sound plays. Remove
        # > `this_frame:`.
        #
        # An effect on a timer starts as the player plays the next frame, where the frame's ticks of the
        # timer are counted, so it has no first frame to play where it is asked. The build stops at the
        # line that asks.
        #
        #--
        # Builder#play_sound_effect refuses the same as the game is written; this holds a tree made
        # another way to it. The players never start an effect on a timer from where the game asks:
        # their way in for `this_frame:` plays the effect's first frame straight away, which the timer
        # would not.
        #++
        class EffectOnTimerThisFrame
          NAME = :effect_on_timer_this_frame
          PLAIN_NAME = "a sound effect on a timer started where it is asked"

          def detect(program)
            timed = program.walk.select { |node| node.kind == :song && node.timer_rate }.to_set(&:name)
            return [] if timed.empty?

            lists = program.walk.select { |node| node.kind == :sound_effect_list }.to_h { |node| [node.name, node.effects] }
            program.walk.filter_map do |node|
              next unless node.kind == :play_sound_effect && node.this_frame
              next unless lists.fetch(node.name, []).any? { |effect| timed.include?(effect) }

              Finding.new(check: NAME, severity: :error, message: message(node.name), node: node)
            end
          end

          private

          def message(list)
            "Sound effect list :#{list} is played with `this_frame: true`, and its sound effects have `on_timer: true`. " \
              "An effect on the timer starts when the next frame's sound plays. Remove `this_frame:`."
          end
        end
      end
    end
  end
end
