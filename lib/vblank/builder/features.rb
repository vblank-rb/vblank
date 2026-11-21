# frozen_string_literal: true

module VBlank
  class Builder
    # Features
    #
    # A feature is a part of a game that a build can leave out. The game names its features where
    # it is named, for example `features: { hero: %i[lamp], lamp: [], bat: [] }`, and asks
    # `feature?` to build a part only where it is wanted.
    #--
    # See Cartridge::Features.
    #++
    module Features
      # Asks whether this build has a feature. The answer is a Ruby true or false while the game
      # is built, as `built_for?` gives, so what a feature holds is built only where it is asked for.
      #
      # ```ruby
      # if feature?(:bat)
      #   bat_x = var :bat_x, 0
      #   func(:bat_flies) { bat_x += 2 }
      # end
      # ```
      #
      # The whole game has every feature. A build made with `game.with_features(:hero)` has the
      # hero and what he brings. Asking about a feature the game does not declare is an error,
      # since no build could ever answer yes and it is almost always a misspelt name.
      #
      # * `name` - the feature's name, as a symbol.
      def feature?(name)
        Cartridge::Features.refuse_undeclared!(@build_options.features, name, "The game asks `feature?(:#{name})`")
        @build_options.feature_built?(name)
      end
    end
  end
end
