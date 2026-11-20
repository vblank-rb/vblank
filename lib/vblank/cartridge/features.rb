# frozen_string_literal: true

module VBlank
  module Cartridge
    # THE PARTS OF A GAME A BUILD CAN LEAVE OUT, and what each brings with it, as the game names them:
    #
    #   VBlank.game "CAVE", consoles: %i[gba], features: { hero: %i[lamp], lamp: [], bat: [] } do
    #     ...
    #     if feature?(:bat)          # a Ruby true or false while the game is built
    #       bat_x = var :bat_x, 0
    #       func(:bat_flies) { ... }
    #     end
    #
    # A build of the whole game has every feature. `game.with_features(:hero)` is the same game
    # built with the hero and what he brings, the lamp, and nothing else: what the block leaves out
    # for the bat (its variables, routines, tables and pictures) is never built, so no lowering
    # makes it and no cartridge holds it. That is the smallest game a test can ask a question of,
    # and the build a test shares with others (Testing::CartridgeCache keys on the features).
    #
    # It is how Cargo's features work: a name for a piece of the program, and the names it turns on
    # besides itself. A game's own description of its parts (which rooms, who stands where) goes on
    # top of this, through `setting` for values and features for the pieces that come or go.
    #
    # Not to be mistaken for `part` (Builder::Parts), which groups what a game declares so that
    # `start_over` can put it back: a part is always built.
    module Features
      # +declared+, the game's `features:`, checked and held shareable: each name a Symbol, each
      # bringing a list of names the game declares too.
      def self.refuse_unusable!(declared)
        unless declared.is_a?(Hash) && declared.all? { |name, brings| name.is_a?(Symbol) && brings.is_a?(Array) }
          raise ArgumentError, "features: names each feature and the features it brings, like " \
                               "`features: { hero: %i[lamp], lamp: [] }`. It was given #{declared.inspect}."
        end
        declared.each do |name, brings|
          unknown = brings.find { |brought| !declared.key?(brought) } or next

          raise ArgumentError, "The feature :#{name} brings :#{unknown}, and the game declares no feature :#{unknown}. " \
                               "To fix this, add `#{unknown}: []` to features:, or remove :#{unknown} from what :#{name} brings."
        end
        Ractor.make_shareable(declared.transform_values { |brings| brings.dup })
      end

      # The features a build of +names+ has, out of +declared+: each of them and everything each
      # brings, in the order the game declared them. A name the game does not declare is refused.
      def self.brought_by(declared, names)
        names.each { |name| refuse_undeclared!(declared, name, "The build asks for the feature :#{name}") }
        built = []
        waiting = names.dup
        until waiting.empty?
          name = waiting.shift
          next if built.include?(name)

          built << name
          waiting.concat(declared.fetch(name))
        end
        Ractor.make_shareable(declared.keys & built)
      end

      # Raise in plain words unless +declared+ names +name+. +asked+ is the start of the sentence:
      # who asked for it.
      def self.refuse_undeclared!(declared, name, asked)
        return if declared.key?(name)

        if declared.empty?
          raise ArgumentError, "#{asked}, and the game declares no features. To fix this, name them where the game is " \
                               "named: `VBlank.game \"NAME\", consoles: ..., features: { #{name}: [] }`."
        end
        raise ArgumentError, "#{asked}, and the game declares no feature :#{name}. It declares " \
                             "#{declared.keys.map { |known| ":#{known}" }.join(', ')}. To fix this, use one of those " \
                             "names, or add `#{name}: []` to features:."
      end
    end
  end
end
