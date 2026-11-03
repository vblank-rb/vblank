# frozen_string_literal: true

module VBlank
  module IR
    module Guardrails
      module Checks
        # A sprite shown over a painted screen (`sprite ..., over_picture: true`) in a game that also
        # has a screen drawn from tiles.
        #
        # ON A PAINTED SCREEN THE CONSOLE'S SPRITE LAYER IS USUALLY OFF. A game that goes between a
        # painted screen and a tiled one keeps its tiled screens' sprites in the console's table,
        # and the layer is switched off while the painted screen is up, so they do not show over it.
        # A sprite over the picture needs that layer on, and then every sprite in the table shows:
        # the tiled screens' too. Telling the two kinds apart on every change of screen is not made,
        # so such a game is refused. Asked by the interpreter and by each console's lowering as well
        # as by the build, so all of them stop with the same words.
        class SpriteOverPictureBesideTiles
          NAME = :sprite_over_picture_beside_tiles
          PLAIN_NAME = "a sprite shown over a painted screen in a game that also has a tiled screen"

          def detect(program)
            sprite = program.walk.find { |node| node.kind == :object && node.over_picture }
            return [] unless sprite && Modes.resolve(program).crosses_display_systems?

            name = sprite.declared || sprite.name
            [Finding.new(check: NAME, severity: :error, node: sprite,
                         message: "The sprite :#{name} is shown over_picture: true on a painted (bitmap) screen, " \
                                  "and this game also has a tiled screen. A game with a sprite over a painted " \
                                  "screen can have painted screens only. To fix this, remove over_picture: true " \
                                  "from :#{name}, or use painted screens only in this game.")]
          end

          # Why the game is refused, or nil when it is not: the words the interpreter and each
          # lowering stop with too.
          def refusal_message(program)
            detect(program).first&.message
          end
        end
      end
    end
  end
end
