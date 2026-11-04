# frozen_string_literal: true

module VBlank
  module DSL
    # What `mark over: hero, with: :arrow` hands back: a picture shown over a sprite, which has no
    # place of its own. Its place is worked out from the sprite's on every frame, and it is shown
    # while the sprite is shown and the `if`s it was written under hold. So nothing about it is a
    # variable, and every way of moving, showing or hiding it is refused here in plain words.
    #
    # That is the point of it. In a match over a network a variable is part of what every machine
    # must agree on, and a mark is how one machine shows something the others do not (the "you"
    # arrow over its own player, in `drawing_for_local_player`). A mark with a place the game could
    # write would be a variable the machines disagree about.
    class Mark
      def initialize(sprite_name)
        @sprite_name = sprite_name
      end

      # Written out one by one, not made in a loop with define_method: a method made from a block
      # cannot be called from a Ractor other than the one that made it, and tests play in Ractors.
      def x(*) = refuse_place_change!(:x)
      def y(*) = refuse_place_change!(:y)
      def x=(_)
        refuse_place_change!(:x=)
      end

      def y=(_)
        refuse_place_change!(:y=)
      end

      def move(*, **) = refuse_place_change!(:move)
      def move_to(*) = refuse_place_change!(:move_to)
      def show = refuse_place_change!(:show)
      def hide = refuse_place_change!(:hide)

      private

      def refuse_place_change!(word)
        raise ArgumentError, "A mark has no place of its own, so you cannot use `#{word}` on it. The mark is " \
                             "always over the sprite :#{@sprite_name}. It shows only when that sprite shows. " \
                             "To move the mark, move the sprite. To show the mark only some of the time, put " \
                             "an `if` around `mark`."
      end
    end
  end
end
