# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # THE DOS LOWERING, NOT WRITTEN YET: the kit, the answers and the description say what DOS is, and
        # this is where its code generator goes (the next piece of work). Until then every kind of step is
        # refused by name, so a game for DOS is told in plain words that the build is not made, and no
        # program is written that does nothing.
        class Lowering
          # The kinds of step the build does not make yet, by the part of the build they wait on
          # (Console::DOSAnswers#reference writes them on the page).
          NOT_LOWERED_YET = Ractor.make_shareable({ "the whole program: the code generator is not written" => [:all] })
        end
      end
    end
  end
end
