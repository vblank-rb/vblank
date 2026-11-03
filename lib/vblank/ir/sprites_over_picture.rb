# frozen_string_literal: true

module VBlank
  module IR
    # SPRITES SHOWN OVER A PICTURE THE GAME PAINTS (`sprite ..., over_picture: true`): the
    # console's own sprites on a bitmap screen, drawn over the picture and never into it.
    #
    # A question about the program, asked by the interpreter, by every lowering that draws one
    # and by the guardrail that refuses one beside a tiled screen, so it is answered here once.
    module SpritesOverPicture
      module_function

      # The first sprite +program+ shows over a painted picture, or nil when it shows none.
      def first_in(program) = program.walk.find { |node| node.kind == :object && node.over_picture }

      # Does +program+ show any sprite over a painted picture?
      def any?(program) = !first_in(program).nil?

      # The frame's sprite step of +program+, the one each frame places its sprites from.
      def frame_sprite_step(program) = program.walk.find { |node| node.kind == :present_objects }
    end
  end
end
