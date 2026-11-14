# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # THE WRITES TO A BACKGROUND THAT EVERY CARTRIDGE LOWERING WRITES ALIKE (the Color's, the Super Nintendo's,
      # the Genesis's and the PlayStation's): which declaration a change to a background goes to, and a
      # background put up in a pass held at its corner through that pass. Where the labels go and what is
      # tested is the program's; how a label, a jump and a store are written is each processor's. Written
      # out in each lowering, the copies were the same but for the console's name for a fresh label.
      #
      # WHAT THE LOWERING SUPPLIES: the ControlFlow hooks fresh_label, place_label, jump, jump_unless, keep_local,
      # statement and emit_store_zero, its plan (@plan, LoweringPlan), and, for #for_background, @scene, the
      # variable the scene up is kept in, and @lowering_scene, the scene whose routine is being written, or nil.
      module SceneryWrites
        # THE DECLARED BACKGROUND a scroll, a changed cell or a map handed over names, as the routine being written
        # sees it (LoweringPlan#background_named); nil where that cannot be told while the game is built.
        def background_declared_for(node) = @plan.background_named(node, scene: @lowering_scene)

        # +node+'s change made to the background it names (#background_declared_for), yielded to the block. Where
        # that is not known while the game is built (a change outside every scene's routine, to a name several
        # scenes declare), the change is made to the one of the scene up when it runs, each scene its own branch.
        def for_background(node)
          bg = background_declared_for(node)
          return yield(bg) if bg

          @plan.scenes.each do |scene, number|
            own = @plan.handover.arrival(scene).scenery.find { |declared| declared.name == node.name }
            next unless own

            other = fresh_label("not_scene")
            jump_unless(Build.binop(:==, Build.var_ref(@scene), Build.int(number)), other)
            yield own
            place_label(other)
          end
        end

        # A BACKGROUND WHOSE LINE CAN RUN MORE THAN ONCE (one in a routine, or in the game loop) is up already the
        # second time, and the interpreter puts it up as it now is: the cells the game changed, and the map it
        # chose, stay (Reference#put_up_background keeps its copy of the map). So its declared map is copied onto
        # its layer the first time alone, noted in a number of the lowering's own for +layer+; every time after,
        # it goes up keeping what the layer holds. The block writes the put-up, handed true where it keeps the
        # cells. A line written once in the program, before or after the game loop, runs once and needs no note.
        #
        # Only a background every screen shows comes this way: a scene's own goes up as its scene takes over,
        # as declared (IR::SceneHandover), and its layer is another's while it is down.
        def emit_put_up_keeping_cells(bg, layer)
          return yield(false) if bg.parent&.kind == :program

          copied = (@cells_copied ||= {})[layer] ||= keep_local(:"cells_copied_#{layer}")
          kept = fresh_label("cells_kept")
          done = fresh_label("put_up_done")
          jump_unless(Build.binop(:==, Build.var_ref(copied), Build.int(0)), kept)
          statement(Build.set(copied, 1))
          yield false
          jump(done)
          place_label(kept)
          yield true
          place_label(done)
        end

        # How a status bar's top is held at its corner (#keep_corner_notes): :own_note where a bar has a note of
        # its own, :layer_note where it is a layer like the others and its layer's note holds it, and nil where
        # the build places no bar's top.
        BAR_NOTES = [:own_note, :layer_note, nil].freeze

        # A BACKGROUND PUT UP IN A PASS SHOWS FROM ITS CORNER ON THAT PASS'S FRAME (Reference#put_up_background),
        # and the place the game keeps for its view, or the top it keeps for a status bar, is written at the
        # end of the pass (IR::Frames.loop_in_console_order), after the put-up. So a put-up notes itself for the
        # rest of its pass, a note for each of +layers+ (the numbers of the layers a background goes up on), and
        # the write at the end of it leaves the background or bar where it was put up. The wait forgets the
        # notes (#emit_corners_forgotten), and the next pass's write moves it. +bar+ is one of BAR_NOTES.
        #
        # Notes are kept only where such a write is placed at the end of a pass; a put-up notes itself through
        # #corner_note and #bar_note, which are nil otherwise.
        def keep_corner_notes(layers, bar:)
          raise ArgumentError, "no way of holding a bar named #{bar.inspect}" unless BAR_NOTES.include?(bar)

          kinds = bar == :layer_note ? %i[scroll_background place_bar] : %i[scroll_background]
          if @plan.places_at_pass_end?(*kinds)
            @put_up_this_pass = layers.to_h { |layer| [layer, keep_local(:"put_up_this_pass_#{layer}")] }
          end
          @bar_up_this_pass = keep_local(:bar_up_this_pass) if bar == :own_note && @plan.places_at_pass_end?(:place_bar)
        end

        # The note a background put up on layer +layer+ sets this pass, or nil where none is kept.
        def corner_note(layer) = @put_up_this_pass&.fetch(layer)

        # The note a status bar put up sets this pass, where it has one of its own, or nil.
        def bar_note = @bar_up_this_pass

        # The notes forgotten at a wait: the pass that put a background up has ended.
        def emit_corners_forgotten
          [*@put_up_this_pass&.values, @bar_up_this_pass].compact.each { |note| emit_store_zero(note) }
        end

        # +node+'s write, unless it is written at the end of a pass that put its background or bar up (+note+,
        # #corner_note or #bar_note).
        def emit_unless_put_up(node, note)
          return yield unless note && @plan.placed_at_pass_end?(node)

          held = fresh_label("held_at_corner")
          jump_unless(Build.binop(:==, Build.var_ref(note), Build.int(0)), held)
          yield
          place_label(held)
        end
      end
    end
  end
end
