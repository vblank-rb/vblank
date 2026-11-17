# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # A RUN OF SPRITES DRAWN IN THE ORDER A LIST HOLDS, READ AS THE INTERPRETER READS ANY LIST
      # (Reference#names_in_draw_order), for the Color's, the Super Nintendo's, the Genesis's and the
      # PlayStation's lowerings: every entry the list holds now, however many; a place below nought counting back
      # from the run's last sprite, as a Ruby array's does; and a place naming none of the run's
      # sprites stopping the game with the interpreter's words (CartridgeFaults::DRAW_ORDER_NAMES_NONE).
      #
      # The Color, the Super Nintendo and the Genesis read the builder's own list a slot an entry, with
      # nothing tested: that list holds every place of its run once, always (Build::DrawOrder#permutation).
      # The PlayStation walks every list here, the builder's too. This walk is for every other
      # list — one written by hand, or one the game takes items from the front of, whose slots move
      # round — so each of those consoles stops on a bad entry where the interpreter stops, rather
      # than placing nothing on one and jumping through a stray address on another.
      #
      # WHAT THE LOWERING SUPPLIES, beside ControlFlow's fresh_label, place_label, jump, jump_unless,
      # keep_local, statement and emit_increment:
      #
      #   emit_draw_order_fault(name, count)   the game stopped: the variable +name+ holds a place
      #                                        that names none of the run's +count+ sprites
      #
      # and a block, handed the variable holding the place of the sprite to place next, from nought
      # up, which places it through the lowering's table of the run's placings. A lowering that keeps
      # something in registers from one sprite to the next writes #emit_sprite_walk_read its own way,
      # keeping them through a read of the list (the Genesis).
      #
      # The Advance's cartridge copies only a list read a slot an entry, and refuses any other
      # (GBA::SpriteDrawing.plan_draw_runs), so it asks DrawOrderWalk.read_by_slots? too.
      module DrawOrderWalk
        # Whether a lowering may read +run+'s list a slot an entry with nothing tested: the builder's
        # own list, which nothing takes items from the front of (+dropped_from_front+, the names of
        # the lists something does).
        def self.read_by_slots?(run, dropped_from_front) = run.permutation && !dropped_from_front.include?(run.order)

        def order_read_by_slots?(run, dropped_from_front) = DrawOrderWalk.read_by_slots?(run, dropped_from_front)

        # The variable +name+ set to +value+, a read of the list.
        def emit_sprite_walk_read(name, value) = statement(Build.set(name, value))

        # +run+'s list walked as the interpreter reads it, the block placing each sprite. +from_back+
        # walks it last entry first, for a console whose sprite table is written front-most first.
        #
        # Where two entries name no sprite, the one walked first is the one the game stops on: the
        # last of them on a console walking from the back, where the interpreter names the first. The
        # game stops on the same frame either way.
        #
        # +from+, a value, is the first entry walked from the front, where it is not the first: the
        # entries before it are ones its sort found not showing (IR ListSort's +shown+).
        def emit_draw_order_walk(run, from_back: false, from: nil)
          count = run.objects.length
          index = keep_local(:draw_order_index)
          place = keep_local(:draw_order_place)
          next_entry = fresh_label("next_draw_order_entry")
          counted = fresh_label("draw_order_place_counted")
          fault = fresh_label("draw_order_names_none")
          done = fresh_label("draw_order_walked")
          if from_back
            emit_draw_order_index_from_back(run, index, next_entry, done)
          else
            emit_draw_order_index_from_front(run, index, place, next_entry, done, from || Build.int(0))
          end
          emit_sprite_walk_read(place, Build.list_get(run.order, Build.var_ref(index)))
          entry = Build.var_ref(place)
          jump_unless(Build.binop(:<, entry, Build.int(count)), fault)
          jump_unless(Build.binop(:>=, entry, Build.int(-count)), fault)
          jump_unless(Build.binop(:<, entry, Build.int(0)), counted)
          statement(Build.set(place, Build.binop(:+, entry, Build.int(count))))
          place_label(counted)
          yield place
          emit_increment(index) unless from_back
          jump(next_entry)
          place_label(fault)
          emit_draw_order_fault(place, count)
          place_label(done)
        end

        private

        # The index from +from+, on to +done+ once it reaches the list's length, read again for every
        # entry (into +place+ until the entry is read over it).
        def emit_draw_order_index_from_front(run, index, place, next_entry, done, from)
          statement(Build.set(index, from))
          place_label(next_entry)
          emit_sprite_walk_read(place, Build.list_len(run.order))
          jump_unless(Build.binop(:<, Build.var_ref(index), Build.var_ref(place)), done)
        end

        # The index from the list's length, a step down before each entry, on to +done+ at nought.
        def emit_draw_order_index_from_back(run, index, next_entry, done)
          emit_sprite_walk_read(index, Build.list_len(run.order))
          place_label(next_entry)
          jump_unless(Build.binop(:>, Build.var_ref(index), Build.int(0)), done)
          statement(Build.set(index, Build.binop(:-, Build.var_ref(index), Build.int(1))))
        end
      end
    end
  end
end
