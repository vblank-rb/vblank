# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/modes").to_s
require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # MORE THAN ONE BACKGROUND SHOWN ALONE ABOVE A ROW ON ONE SCREEN (`above_row:` with
        # `alone: true` or `alone: :without_sprites`).
        #
        # Alone means no other background shows on the rows above that one, so two at once ask for
        # opposite things on the same rows. A console's display draws one of them that way: the
        # Super Nintendo's line table takes the first one declared and draws the second wrong, and
        # the interpreter and the computer builds need not pick the same one. Counted a screenful at
        # a time (IR::Stacking#screenfuls), so each scene can show one of its own.
        class TooManyBackgroundsAlone
          NAME = :too_many_backgrounds_alone
          PLAIN_NAME = "more than one background shown alone above a row on one screen"

          def detect(program)
            Stacking.screenfuls(program).each do |screenful|
              alone = screenful.scenery.select(&:alone)
              next if alone.size <= 1

              return [Finding.new(check: NAME, severity: :error, node: alone[1], message: message(alone, screenful.scene))]
            end
            []
          end

          # Why the backgrounds are refused, or nil when they fit — the words the interpreter and each
          # lowering stop with too.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def message(alone, scene)
            subject = scene ? "The scene :#{Modes.strip_scene_prefix(scene)}" : "This game"
            hint = scene ? "" : " Each scene can show its own background alone."
            names = alone.map { |bg| ":#{bg.name}" }
            "#{subject} shows #{names[0...-1].join(', ')} and #{names.last} alone above a row at one time. " \
              "Only one background can show alone above its row. To fix this, remove `alone:` from all but one of them.#{hint}"
          end
        end
      end
    end
  end
end
