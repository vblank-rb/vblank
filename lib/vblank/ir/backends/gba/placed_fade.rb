# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # An effect placed in the stack.
        #
        # `fade :black, 100, under: :ui` blends what is behind :ui and leaves :ui and
        # everything in front of it alone. The console has two ways to set that, and the
        # asymmetry between them is what shapes all of this:
        #
        #   * The blend register names each background layer with a bit of its own, so
        #     scenery on the kept side simply stays out of the mask. Free.
        #   * It names every sprite on screen with one bit. So a line drawn between two
        #     sprites cannot be set there at all — and a HUD is sprites, which makes
        #     that the case the whole feature exists for.
        #
        # The way through is the object window. A sprite can be drawn as a window instead
        # of a picture: it paints nothing, and where its pixels would have been the color
        # effect is turned off. The region is the shape of the pixels it paints and not
        # its box, which is what makes it usable for a letter. So each kept sprite gets a
        # twin drawn that way, and the fade goes around the sprite.
        #
        # A twin costs one sprite slot and one table write a frame, so they are made only
        # where they are the only answer: a fade that keeps every sprite leaves the OBJ
        # bit out of the mask instead, and costs nothing at all.
        #
        # A twin is a rider on its sprite rather than a second sprite to work out. Where it
        # is, which pose it holds and how big it is are all the same numbers, so the frame
        # writes them once and drops a copy into the twin's slot on the way past (see
        # SpriteDrawing#emit_present_object) — which is what keeps a HUD held out of a fade from
        # costing as much again as the HUD.
        #
        # Its gate is where the fade in force is sitting: EFFECT_LINE against this sprite's
        # place in the stack. So a program that also fades the whole screen somewhere else
        # puts the twins away for that one, and the HUD goes down with the game — which is
        # what a whole-screen fade means.
        #
        # Nothing to do — and not one emitted byte different — for a program that places no
        # fade, which is every program that names no layers.
        class PlacedFade
          include Console::Hardware

          # The window that keeps one sprite out of the fade: which place in the console's
          # table it takes, and when it shows.
          Twin = Data.define(:slot, :gate)

          def initialize(picture, program)
            @picture = picture
            @gates = program.walk.filter_map { |node| node.under if node.kind == :fade }
                            .uniq
                            .flat_map { |layer| sprites_needing_window(layer) }
                            .uniq(&:name)
                            .to_h { |node| [node.name, window_shown_condition(node)] }
            @twins = {}
          end

          # The twins take the front places, each one a run as long as the sprite it shadows
          # — a twin has to hold exactly the shape the sprite holds, so a sprite drawn as
          # four objects needs four windows. The block gives how many places a sprite takes.
          # Returns where the real sprites start.
          def place_fade_windows
            front = 0
            @twins = @gates.to_h do |name, gate|
              at = front
              front += yield(name)
              [name, Twin.new(slot: at, gate: gate)]
            end
            front
          end

          def fade_window_for(name) = @twins[name]
          def none? = @gates.empty?
          def any? = !none?
          def count = @gates.size
          def names = @gates.keys

          # How many of the console's places the twins take between them.
          def places_spent(&pieces) = @gates.keys.sum(&pieces)

          # Which layers a fade blends: everything behind where it sits. A fade that names no
          # layer reaches the whole screen.
          def blend_target_bits(under)
            return BLD_ALL_LAYERS if under.nil?

            kept = IR::Stacking.at_or_above(@picture, under).map(&:name)
            bits = BLD_BACKDROP # the backdrop is behind everything, so a placed fade always reaches it
            @picture.scenery.each_with_index do |node, layer|
              bits |= (BLD_BG0 << layer) unless kept.include?(node.name)
            end
            bits |= BLD_OBJ if @picture.objects.any? { |node| fade_reaches?(node, under, kept) }
            bits
          end

          # Where in the stack a fade sits. One past the front for a fade that names no
          # layer, so no twin is ever shown for it — which is also where it starts at boot,
          # before any fade is placed.
          def fade_stack_index(under = nil) = under.nil? ? @picture.stack.length : @picture.stack.index(under)

          private

          # The sprites a fade under +layer+ has to hold itself off one at a time. None when
          # every sprite is on the kept side: they then leave the blend's target list
          # together, which is one register bit and no twins at all.
          def sprites_needing_window(layer)
            kept = IR::Stacking.at_or_above(@picture, layer).map(&:name)
            return [] unless @picture.objects.any? { |node| fade_reaches?(node, layer, kept) }

            @picture.objects.select { |node| fade_can_keep?(node, layer, kept) }
          end

          # Can a fade under +layer+ reach +node+: is it behind the line, in some layer it can be in?
          # +kept+ is the names IR::Stacking.at_or_above gives for that line, by the layer each was
          # declared in.
          def fade_reaches?(node, layer, kept)
            return !kept.include?(node.name) unless changes_layer?(node)

            line = @picture.stack.index(layer)
            !kept.include?(node.name) || sprite_layers(node).any? { |name| stack_place(name) < line }
          end

          # Can a fade under +layer+ leave +node+ alone: is it at the line or in front, in some layer
          # it can be in?
          def fade_can_keep?(node, layer, kept)
            return kept.include?(node.name) unless changes_layer?(node)

            line = @picture.stack.index(layer)
            kept.include?(node.name) || sprite_layers(node).any? { |name| stack_place(name) >= line }
          end

          # Where in the stack +layer+ is, or one behind the back for a thing in no layer, which every
          # placed fade reaches.
          def stack_place(layer) = @picture.stack.index(layer) || -1

          # Can the game put +node+ in another layer as it runs (`put_in_layer`)?
          def changes_layer?(node) = !node.layers.nil? && !node.layers.empty?

          # The layers a sprite can be in: each it can be put in, counted as its layer variable counts
          # them, then the one it was declared in, which a number naming none of them leaves it in.
          def sprite_layers(node) = [*node.layers, node.layer]

          # The twin shows while the fade in force sits at or behind the layer the sprite is in now.
          # A sprite that can be put in other layers asks which one its layer variable picks, as the
          # sprite's depth does (ScreenLayout#sprite_layer_depth_table).
          def window_shown_condition(node)
            return shown_at_or_in_front(stack_place(node.layer)) unless changes_layer?(node)

            pick = Build.var_ref(node.layer_pick)
            chosen = node.layers.each_with_index.map do |layer, at|
              Build.binop(:and, Build.binop(:==, pick, Build.int(at)), shown_at_or_in_front(stack_place(layer)))
            end
            none = Build.binop(:or, Build.binop(:<, Build.var_ref(node.layer_pick), Build.int(0)),
                               Build.binop(:>=, Build.var_ref(node.layer_pick), Build.int(node.layers.length)))
            declared = Build.binop(:and, none, shown_at_or_in_front(stack_place(node.layer)))
            (chosen + [declared]).reduce { |either, other| Build.binop(:or, either, other) }
          end

          def shown_at_or_in_front(place) = Build.binop(:<=, Build.var_ref(EFFECT_LINE), Build.int(place))
        end
      end
    end
  end
end
