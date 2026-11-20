# frozen_string_literal: true

module VBlank
  class Builder
    # WHETHER THIS BUILD HAS A FEATURE: the parts of a game a build can leave out, named where the
    # game is named (`features: { hero: %i[lamp], lamp: [], bat: [] }`; see Cartridge::Features).
    module Features
      # WHETHER THIS BUILD HAS THE FEATURE +name+: a Ruby true or false while the game is built, as
      # `built_for?` is, so what a feature holds is built only where it is asked for.
      #
      #   if feature?(:bat)
      #     bat_x = var :bat_x, 0
      #     func(:bat_flies) { bat_x += 2 }
      #   end
      #
      # The whole game has every feature; `game.with_features(:hero)` has the hero and what he
      # brings. Asking about a feature the game does not declare is refused, since no build could
      # ever answer yes: it is almost always a misspelt name.
      def feature?(name)
        Cartridge::Features.refuse_undeclared!(@build_options.features, name, "The game asks `feature?(:#{name})`")
        @build_options.feature_built?(name)
      end
    end
  end
end
