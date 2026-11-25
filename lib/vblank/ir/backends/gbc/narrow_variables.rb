# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # The variables that only ever hold a byte or two, though the game never declared them
        # narrow, so the Color's lowering keeps each in one byte or two (Lowering::KeptVariables).
        # The Color's processor works a byte at a time, and a four-byte variable read as a list's
        # index is four loads, a bounds check through general code and a whole number made of it;
        # most of a pool's own variables (where its walk is, the slot it took, its links) never hold
        # more than a byte, and a place on the screen or a step never more than two. Keeping one
        # narrow changes nothing the game computes: every write to it is proven to give a number
        # its bytes hold exactly, -128 to 127 or -32768 to 32767 (Backends::NumberRanges says how),
        # and a read copies its sign upward to make the whole number again
        # (KeptVariables#load_kept_variable).
        #
        # Kept whole besides what the proof cannot bound: one a sprite is placed from as it stands
        # (#sprite_numbers_read_whole), and the ones the lowering names (+also_whole+).
        class NarrowVariables
          # +also_whole+ is variables the lowering writes or reads in four bytes itself, outside
          # any statement of +program+.
          def initialize(program, also_whole: [])
            sprites = program.walk.select { |node| node.kind == :object }.flat_map { |object| sprite_numbers_read_whole(object) }
            ranges = NumberRanges.new(program, also_whole: also_whole + sprites)
            @bytes = ranges.variables_within(NumberRanges::BYTE)
            @halves = ranges.variables_within(NumberRanges::HALF) - @bytes
          end

          # The variables kept in a byte, and those kept in two, each in the order the program first
          # writes them.
          attr_reader :bytes, :halves

          private

          # The variables a sprite is placed from as they stand: its pose, its place, its list, whether
          # it is on, and the variable picking a scene's sprites (Picture#showing_parts). A sprite
          # kept as it was is placed by the runtime from a block naming where each of these is kept,
          # read as a whole number there (Picture#posed_sprite_block), so they stay whole and keep
          # that quick way open. A variable only worked into one (`stacked > 31`) is not one.
          def sprite_numbers_read_whole(object)
            active = object.active
            on, scene = active, nil
            if active.is_a?(Node) && active.kind == :binop && active.op == :*
              on = active.lhs
              scene = active.rhs.lhs if active.rhs.is_a?(Node) && active.rhs.kind == :binop && active.rhs.op == :==
            end
            [on, scene, object.pose, object.x, object.y, object.recolor]
              .filter_map { |number| number.name if number.is_a?(Node) && number.kind == :var_ref }
          end
        end
      end
    end
  end
end
