# frozen_string_literal: true

module VBlank
  module DSL
    # Marks over sprites
    #
    # A mark is a picture shown over a sprite, made with `mark over: hero, with: :arrow`. It has
    # no place of its own: on every frame it stands where its sprite is, and it shows while the
    # sprite shows and the `if`s it was written under hold. So a mark cannot be moved, shown or
    # hidden by itself. Move the sprite to move it, and put an `if` round `mark` to show it only
    # some of the time.
    #
    # ```ruby
    # drawing_for_local_player do |me|
    #   walkers.each.with_index(1) { |walker, player| mark over: walker, with: :you_arrow if me == player }
    # end
    # ```
    #
    # That is what makes it safe in a match over a network. Every machine in a match must agree
    # on every variable, and a mark is how one machine shows something the others do not, such
    # as the arrow over its own player.
    class Mark
      def initialize(sprite_name)
        @sprite_name = sprite_name
      end

      # Written out one by one, not made in a loop with define_method: a method made from a block
      # cannot be called from a Ractor other than the one that made it, and tests play in Ractors.

      # Refused: a mark has no place of its own. It stands where its sprite is.
      def x(*) = refuse_place_change!(:x)

      # Refused: a mark has no place of its own. It stands where its sprite is.
      def y(*) = refuse_place_change!(:y)

      # Refused: a mark has no place of its own. Move its sprite instead.
      def x=(_)
        refuse_place_change!(:x=)
      end

      # Refused: a mark has no place of its own. Move its sprite instead.
      def y=(_)
        refuse_place_change!(:y=)
      end

      # Refused: a mark has no place of its own. Move its sprite instead.
      def move(*, **) = refuse_place_change!(:move)

      # Refused: a mark has no place of its own. Move its sprite instead.
      def move_to(*) = refuse_place_change!(:move_to)

      # Refused: a mark shows while its sprite shows. Put an `if` round `mark` instead.
      def show = refuse_place_change!(:show)

      # Refused: a mark shows while its sprite shows. Put an `if` round `mark` instead.
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
