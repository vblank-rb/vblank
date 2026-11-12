# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHICH SHAPE A `repeat` IS LOWERED TO ON A CARTRIDGE, decided from the program alone, for
      # every console whose loops Backends::ControlFlow writes.
      #
      # A loop keeps a count of the turns it has made. The interpreter keeps that count to itself
      # and hands it to the game's variable at the top of each turn (Reference#exec_repeat), so a
      # body that wrote the variable would not change how many turns are made. Kept that way on a
      # console, every turn copies the count into the variable: a load and a store that most loops
      # have no use for, since nothing but the loop ever writes its variable.
      #
      # So the question asked here is whether the game's variable can BE the count. It can when
      # the loop is the only statement in the whole program that names it as anything but a number
      # to read: then it holds the turn's number through every turn, as the interpreter's does,
      # and the loop counts in it.
      #
      # THE ADVANCE ASKS MORE, in GBA::LoopForm, which is still its own: whether the count can stay
      # in two registers, whether one statement that would overwrite them can be bracketed, and
      # whether a loop whose index nothing reads can count down. Those answers rest on which
      # registers each kind of statement leaves alone, which is each processor's to say. Sharing
      # them needs each lowering to name the kinds that overwrite its loop registers, the way
      # GBA::LoopForm's three lists do, and a count kept in a register put back in the variable
      # wherever a pass can end, since every variable is compared with the interpreter's then.
      #
      # NOR WHEN A SECOND CALL OF ITS ROUTINE CAN COME while the loop is part way through
      # (LoweringPlan#routines_reentered_at_frame_boundary): the second call's turns write the variable,
      # and the interpreter's loop goes on from its own count, so the count is kept apart and put back.
      class LoopForm
        # +apart_in+: the routines whose loops keep their counts apart from the game's variables.
        def initialize(program, apart_in: [])
          @statements_naming = Hash.new(0)
          program.walk do |node|
            next if node.kind == :var_ref

            Reach::VARIABLES_OF[node.kind]&.call(node)&.each { |name| @statements_naming[name] += 1 }
          end
          @kept_apart = Set.new.compare_by_identity
          Reach.statements_from(*apart_in).each { |node| @kept_apart << node if node.kind == :repeat }
        end

        # Whether +node+, a repeat, can count its turns in the game's own variable: it has one, no
        # other statement names it (Reach::VARIABLES_OF) but to read it, and its routine is not called
        # again while it is part way through.
        def counts_in_index?(node) = !node.index.nil? && @statements_naming[node.index] == 1 && !@kept_apart.include?(node)
      end
    end
  end
end
