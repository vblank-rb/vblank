# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # NAMES MADE FROM ANOTHER NAME: the label just past a routine's last instruction, a label
      # inside a routine, a table that goes with a picture, a number a routine keeps for itself.
      #
      # A lowering names many things after the thing they belong to, and the two names have to
      # agree wherever either is written. Spelt out at each call (the routine's name, then
      # "_end") a misspelt suffix makes a second name that nothing else uses, and nothing says so
      # until a jump has nowhere to go, or never: the profile finds a routine by its end label, and
      # one with a misspelt end is not found, silently. So a derived name is made here, or once
      # in a constant beside its routine, and every call site names it the same way.
      #
      # Every name comes back as a Symbol, which is what each lowering's tables are keyed by.
      #
      # `test/all/vblank/test_derived_names.rb` fails on a Symbol in the lowerings that starts by
      # interpolating another name (ROUTINE, then "_end", in one Symbol literal), the shape every
      # name made from another took. A name that only puts a run-time part after a fixed prefix (`:"__music_note_#{lane}"`)
      # names a family of its own rather than following another name, and is left as it is.
      module DerivedNames
        # The label placed just past +routine+'s last instruction. A routine bracketed by its own
        # name and this one is copied, measured and profiled by the pair (GBA#lowered_routine_addresses).
        def self.routine_end(routine) = sub_label(routine, :end)

        # A label inside +owner+, or a name belonging to it: the owner's name, an underscore, +part+.
        def self.sub_label(owner, part) = join(owner, "_", part)

        # +parts+ written one after another as one Symbol, for a name with its own separator: a
        # suffix constant (Framebuffer::INDEXED_SUFFIX), a scene a background is declared in.
        def self.join(*parts) = parts.join.to_sym

        # The +count+th number a cartridge lowering keeps for +routine+'s own use (`keep_local`),
        # named for what it holds: "game.timer3" for one the game's own code keeps (+routine+ nil).
        def self.local_number_name(routine, what, count) = join(routine || "game", ".", what, count)
      end
    end
  end
end
