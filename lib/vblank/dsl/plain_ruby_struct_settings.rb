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
      # Each is a private method of every class (Module#drawn_as, at the foot of this file) calling
      # here, and the class keeps it in a constant, as `game_variables` names are kept
      # (InstanceVariables.name_in_module), so any Ractor that builds a game can read it.
      module StructSettings

        # The constant a class keeps its look in, as the keywords `pool` takes.
        DRAWING_CONSTANT = :VBLANK_DRAWN_AS

        # The constant a class keeps its narrow fields in, as `pool`'s `widths:`.
        WIDTHS_CONSTANT = :VBLANK_NARROW_FIELDS

        # What `drawn_as` takes besides a picture's name: `pool`'s settings for a thing's look.
        DRAWING_SETTINGS = %i[facing frames rate].freeze

        # The widths `narrow` takes for a field.
        WIDTHS = %i[byte half].freeze

        module_function

        # `drawn_as :spark`, or `drawn_as facing: { left: [...], right: [...] }, rate: 8`: each thing
        # is a sprite at its x and y, showing that picture.
        def drawn_as(owner, image = nil, **settings)
          refuse_outside_class!(owner, :drawn_as)
          refuse_unknown_drawing!(settings)
          refuse_no_place!(owner) if owner < Struct && !(%i[x y] - owner.members).empty?
          drawing = settings.merge(image.nil? ? {} : { image: image })
          store(owner, DRAWING_CONSTANT, drawing)
        end

        # `narrow :x, :y` keeps each in a half word; `narrow x: :byte` names the width.
        def narrow(owner, *fields, **widths)
          refuse_outside_class!(owner, :narrow)
          chosen = fields.to_h { |field| [field.to_sym, :half] }.merge(widths)
          chosen.each_value { |width| refuse_unknown_width!(width) }
          store(owner, WIDTHS_CONSTANT, drawing_of(owner, constant: WIDTHS_CONSTANT).merge(chosen))
        end

        # The look +kind+ and the classes it is made from set, as `pool`'s keywords.
        def drawing_of(kind, constant: DRAWING_CONSTANT)
          kind.ancestors.reverse.each_with_object({}) do |each_module, set|
            set.merge!(each_module.const_get(constant, false)) if each_module.const_defined?(constant, false)
          end
        end

        # The narrow fields +kind+ sets, as `pool`'s `widths:`.
        def widths_of(kind) = drawing_of(kind, constant: WIDTHS_CONSTANT)

        def store(owner, constant, settings)
          owner.class_eval { remove_const(constant) } if owner.const_defined?(constant, false)
          owner.const_set(constant, Ractor.make_shareable(settings))
          nil
        end

        def refuse_outside_class!(owner, name)
          return if owner.is_a?(Class)

          Steps.refuse_game_code!("`#{name}` describes each thing of a Struct, so it goes in the block of " \
                                  "`Struct.new`. To fix this, write it there: `Spark = Struct.new(:x, :y) do " \
                                  "#{name} ... end`.")
        end

        def refuse_unknown_drawing!(settings)
          unknown = settings.keys - DRAWING_SETTINGS
          return if unknown.empty?

          Steps.refuse_game_code!("`drawn_as` does not take `#{unknown.first}:`. It takes a picture's name, and " \
                                  "`facing:`, `frames:` and `rate:`.")
        end

        def refuse_no_place!(owner)
          Steps.refuse_game_code!("`drawn_as` shows each thing as a sprite at its `x` and `y`, and " \
                                  "#{owner.name || 'this Struct'} has no #{(%i[x y] - owner.members).map { |f| "`#{f}`" }.join(' or ')}. " \
                                  "To fix this, add the fields `:x` and `:y` to `Struct.new`.")
        end

        def refuse_unknown_width!(width)
          return if WIDTHS.include?(width)

          Steps.refuse_game_code!("`narrow` takes `:byte` or `:half` for a field, and it was given #{width.inspect}.")
        end
      end
    end
  end
end

# `drawn_as` and `narrow` in a Struct's block, or a class's body. They only keep settings, which
# needs no rewrite, so they work in any file: one a game brings in with `require_relative` too.
class Module
  private def drawn_as(...) = VBlank::DSL::PlainRuby::StructSettings.drawn_as(self, ...)
  private def narrow(...) = VBlank::DSL::PlainRuby::StructSettings.narrow(self, ...)
end
