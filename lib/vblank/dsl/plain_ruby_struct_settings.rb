# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # The settings a Struct's block gives an Array of it kept as a pool (DSL::StructArray), read
      # as Ruby class macros:
      #
      #     Spark = Struct.new(:x, :y, :vy) do
      #       drawn_as :spark       # each thing is a sprite at its x and y
      #       narrow :x, :y         # each kept in a half word
      #     end
      #
      # Each is a private method of every Struct and Data class (Macros, extended into both at the
      # foot of this file), and the class keeps what it was given in a constant, as
      # `game_variables` names are kept (InstanceVariables.name_in_module), so any Ractor that
      # builds a game can read it.
      module StructSettings
        # The constant a class keeps its look in, as the keywords `pool` takes.
        DRAWING_CONSTANT = :VBLANK_DRAWN_AS

        # The constant a class keeps its narrow fields in, as `pool`'s `widths:`.
        WIDTHS_CONSTANT = :VBLANK_NARROW_FIELDS

        # The constant a class a game block made keeps the name it was given in.
        NAME_CONSTANT = :VBLANK_NAME

        # What `drawn_as` takes besides a picture's name: `pool`'s settings for a thing's look,
        # and the layer each thing stands in.
        DRAWING_SETTINGS = %i[facing frames rate layer].freeze

        # The widths `narrow` takes for a field.
        WIDTHS = %i[byte half].freeze

        # `drawn_as` and `narrow`, the class macros of a Struct's block. They only keep settings,
        # which needs no rewrite, so they work in any file: one a game brings in with
        # `require_relative` too.
        module Macros
          private

          # `drawn_as :spark`, or `drawn_as facing: { left: [...], right: [...] }, rate: 8`: each
          # thing is a sprite at its x and y, showing that picture. `layer: :swimmers` stands each
          # in that layer of the stack.
          def drawn_as(image = nil, **settings)
            keep_setting(DRAWING_CONSTANT, StructSettings.drawing(self, image, settings))
          end

          # `narrow :x, :y` keeps each in a half word; `narrow x: :byte` names the width.
          def narrow(*fields, **widths)
            keep_setting(WIDTHS_CONSTANT, StructSettings.widths_of(self).merge(StructSettings.widths(fields, widths)))
          end

          # Must replace the constant, never change what it holds: it is frozen so that every
          # Ractor may read it.
          def keep_setting(constant, settings)
            remove_const(constant) if const_defined?(constant, false)
            const_set(constant, Ractor.make_shareable(settings))
            nil
          end
        end

        module_function

        # What `drawn_as` keeps on +owner+, as `pool`'s keywords.
        def drawing(owner, image, settings)
          refuse_unknown_drawing!(settings)
          refuse_no_place!(owner) unless (%i[x y] - owner.members).empty?
          settings.merge(image.nil? ? {} : { image: image })
        end

        # What `narrow` keeps, as `pool`'s `widths:`.
        def widths(fields, widths)
          chosen = fields.to_h { |field| [field.to_sym, :half] }.merge(widths)
          chosen.each_value { |width| refuse_unknown_width!(width) }
          chosen
        end

        # +kind+, made in a game block and given to the constant +name+ there, which the block
        # keeps as a local of its own (Rewriter#own_classes_in): it keeps the name for messages.
        def own_class(name, kind)
          kind.const_set(NAME_CONSTANT, name.to_s.freeze) if kind.is_a?(Module) && !kind.const_defined?(NAME_CONSTANT, false)
          kind
        end

        # The name a game gave +kind+, as it wrote it: `Spark` for `Sparks::Spark`.
        def name_of(kind)
          return kind.const_get(NAME_CONSTANT) if kind.const_defined?(NAME_CONSTANT)

          kind.name&.split("::")&.last || "Struct"
        end

        # The look +kind+ and the classes it is made from set, as `pool`'s keywords.
        def drawing_of(kind, constant: DRAWING_CONSTANT)
          kind.ancestors.reverse.each_with_object({}) do |each_module, set|
            set.merge!(each_module.const_get(constant, false)) if each_module.const_defined?(constant, false)
          end
        end

        # The narrow fields +kind+ sets, as `pool`'s `widths:`.
        def widths_of(kind) = drawing_of(kind, constant: WIDTHS_CONSTANT)

        def refuse_unknown_drawing!(settings)
          unknown = settings.keys - DRAWING_SETTINGS
          return if unknown.empty?

          Steps.refuse_game_code!("`drawn_as` does not take `#{unknown.first}:`. It takes a picture's name, and " \
                                  "`facing:`, `frames:`, `rate:` and `layer:`.")
        end

        def refuse_no_place!(owner)
          missing = (%i[x y] - owner.members).map { |field| "`#{field}`" }.join(" or ")
          Steps.refuse_game_code!("`drawn_as` shows each thing as a sprite at its `x` and `y`, and " \
                                  "#{name_of(owner)} has no #{missing}. To fix this, add the fields `:x` and `:y` " \
                                  "to `Struct.new`.")
        end

        def refuse_unknown_width!(width)
          return if WIDTHS.include?(width)

          Steps.refuse_game_code!("`narrow` takes `:byte` or `:half` for a field, and it was given #{width.inspect}.")
        end
      end
    end
  end
end

Struct.extend(VBlank::DSL::PlainRuby::StructSettings::Macros)
Data.extend(VBlank::DSL::PlainRuby::StructSettings::Macros)
