# frozen_string_literal: true

module VBlank
  module Effects
    module Packs
      # A picture that is drawn when it changes and then left there
      #
      # A score, a health bar, a game over banner or the words over a finished game need painting
      # only when they change. A picture repainted every frame needs none of this. A picture left
      # alone between changes is much cheaper, and on the tear-free screen (`screen :bitmap,
      # tear_free: true`) leaving it alone needs care. That screen keeps two pictures and shows them
      # in turn, so a change painted a single time reaches one of the two, and the screen flickers
      # between the new figure and the old one. `redraw_on_change` paints a change once for each picture
      # the screen keeps, so a game never writes the number down. On a plain screen the same game
      # code costs one paint. A game moved from `screen :bitmap` to `screen :bitmap, tear_free:
      # true` keeps working, and the flicker that would have appeared never does.
      #
      # ```ruby
      # VBlank.game "HEALTH", consoles: %i[gba] do
      #   screen :bitmap, tear_free: true
      #   health = 100
      #   clear_screen :black
      #   bar = redraw_on_change(:health_bar) do
      #     fill_rect 20, 20, 100, 8, :red
      #     fill_rect 20, 20, health, 8, :green
      #   end
      #   bar.changed
      #   game_loop do
      #     if health > 40
      #       health -= 1
      #       bar.changed # painted again on both pages, and then left alone
      #     end
      #     bar.draw
      #   end
      # end
      # ```
      #
      # ```ruby
      # bar = redraw_on_change(:status_bar) { paint_the_bar }
      # bar.changed if health != last
      # bar.draw
      # ```
      #--
      # A picture that is drawn when it changes and then left there — a score, a
      # health bar, a game over banner, the words over a finished game.
      #
      # What it is for. A picture repainted every frame needs none of this. A picture
      # left alone between changes is much cheaper, and on the tear-free screen
      # (`screen :bitmap, tear_free: true`) leaving it alone needs care: that screen
      # keeps two pictures and shows them in turn, so the program draws into the one
      # nobody is looking at and they trade places at the frame boundary. A change
      # painted a single time therefore reaches one of the two, and the screen flickers
      # between the new figure and the old one, half the frames each. (A Game Boy Color
      # shows a painted picture whole, so it keeps one page even there, and a second
      # paint only draws the same picture again.)
      #
      # So a change is painted once per picture the screen keeps. The game marks when
      # the picture changed; how many paints that takes is read off the screen the game
      # declared, and no game writes the number down.
      #
      #   bar = redraw_on_change(:status_bar) { paint_the_bar }
      #
      #   # ...somewhere a change happens:
      #   bar.changed if health != last
      #
      #   # ...and in the frame, where the picture belongs in the drawing order:
      #   bar.draw
      #
      # On a plain screen the same game code is right and costs one paint, because a
      # screen that keeps one picture needs one. Nothing in the game names which screen
      # it is on, which is the point — a game moved from `screen :bitmap` to
      # `screen :bitmap, tear_free: true` keeps working, and the flicker that would
      # have appeared never does.
      #
      # A pack, by {Effects}'s own test: every line is written in `var`, `func`,
      # `call` and `if`, and no backend knows this file exists.
      #++
      module RedrawOnChange
        # Redraws a picture when the game marks it changed, and leaves it there in between. It works
        # out how many paints a change takes on this screen: one for each picture the screen keeps.
        #
        # The block is the drawing. It is built into a routine of its own and not written out at
        # each place that needs it, so a picture painted from three places costs its code once.
        # Declare it where the picture belongs, at the top level or inside a `scene` that owns it,
        # the same as a `sprite`. It returns a handle: `changed` when the picture changes, and `draw`
        # in the drawing order.
        #
        # ```ruby
        # bar = redraw_on_change(:status_bar) { paint_the_bar }
        #
        # bar.changed if health != last   # somewhere a change happens
        # bar.draw                        # in the frame, where the picture belongs in the drawing order
        # ```
        #
        # * `name` - what to call the picture, as a symbol. Each picture needs its own name.
        # * The block - the drawing.
        def redraw_on_change(name, &drawing)
          unless name.is_a?(Symbol)
            raise ArgumentError,
                  "redraw_on_change needs a name for the picture, as a symbol: " \
                  "redraw_on_change(:status_bar) { ... }. You gave #{name.inspect}."
          end
          unless drawing
            raise ArgumentError,
                  "redraw_on_change needs a block saying what to draw: " \
                  "redraw_on_change(:#{name}) { draw_text \"GAME OVER\", :center, 80, :white }."
          end
          if redraw_on_change_pictures.key?(name)
            raise ArgumentError,
                  "redraw_on_change(:#{name}) was declared twice. Each picture needs its own " \
                  "name. Declare it once and keep the handle it gives back."
          end

          redraw_on_change_pictures[name] = Shown.new(self, name, &drawing)
        end

        #--
        # The verb's old name, kept only to say the new one. Private, so it is no verb of the DSL's:
        # a game's block still reaches it, since it runs as the builder.
        #++
        private def keep_showing(*, &)
          raise ArgumentError, "`keep_showing` is now `redraw_on_change`. To fix this, write `redraw_on_change`."
        end

        # The pictures declared so far, by name — so a double declaration is caught
        # and the guardrail can see what was asked for.
        # Introspection behind `redraw_on_change`: the pictures declared so far. A game reads none of this.
        def redraw_on_change_pictures = @redraw_on_change_pictures ||= {}  # :nodoc:

        # One such picture: a routine that draws it, and a count of how many pages
        # still want it.
        #
        # The count is the whole mechanism. #changed sets it to however many pictures
        # this screen keeps; #draw paints while it is positive and takes one off. So a
        # change is painted on that many frames running, which is one of each page,
        # and nothing in a game ever names a page.
        class Shown
          def initialize(builder, name, &drawing)
            @b = builder
            @name = name
            @pages = builder.screen_pages
            @todo = builder.var(:"__shown_#{name}_todo", 0)
            builder.func(routine, &drawing)
          end

          # The picture changed. Call it at the moment the thing it shows moves — when
          # the score goes up, when the game ends. It paints nothing itself; it marks
          # that every page now wants a fresh copy.
          #
          # Calling it again before the last change has reached both pages simply asks
          # again, so a burst of changes cannot leave a page holding a stale figure.
          def changed
            @todo = @pages
            self
          end

          # Paint it if any page still wants it. Call this every frame, at the point in
          # the drawing order where the picture belongs — over the scene it sits on top
          # of, under anything that covers it. A frame with no change outstanding costs
          # one comparison and draws nothing.
          def draw
            if @todo > 0
              @todo -= 1
              @b.call(routine)
            end
            self
          end

          # Nobody wants it any more. Call it where the thing the picture showed is put
          # back — a new game starting over a finished one. Any paints still owed from
          # the last change are dropped, so a banner cannot follow the game that ended
          # into the one that replaced it. It erases nothing itself; whatever draws next
          # covers it.
          def cancel
            @todo = 0
            self
          end

          # How many times a change is painted on this screen: one per picture the
          # screen keeps.
          attr_reader :pages

          def routine = :"__draw_shown_#{@name}"
        end

        # The guardrails this pack brings with it.
        def self.checks = CHECKS

        # A warning about a picture declared with `redraw_on_change` that the game never draws:
        #
        # > This game declares `redraw_on_change(:<picture>)`, but it never draws that picture. The
        # > block says what to draw. A call to `draw` on the handle is what puts it on screen.
        # > With no such call the picture never appears. To fix this, call `<picture>.draw` in the
        # > frame, where the picture belongs in the drawing order.
        #
        # The two halves sit in different places on purpose: a change is noticed wherever it
        # happens, and the drawing belongs in the frame, in the order things are drawn. So it is
        # easy to write one half and not the other, and then the picture, such as a score, never
        # appears at all. Call `draw` on the handle in the frame.
        #
        #--
        # Left like that the counter goes up on every change and nothing ever reads it.
        #
        # Read structurally, the same way the shake's own check is: the routine is
        # declared as soon as a picture is, and #draw is the only thing that ever
        # places a call to it. A declared routine with no call is exactly this bug.
        #++
        class NeverDrawn
          NAME = :redraw_on_change_never_drawn  # :nodoc:
          PLAIN_NAME = "a picture that is never drawn"  # :nodoc:

          def detect(program)
            declared(program).filter_map do |routine|
              next if called?(program, routine)

              IR::Guardrails::Finding.new(check: NAME, severity: :warning,
                                          message: message_for(routine), node: :program)
            end
          end

          private

          PREFIX = "__draw_shown_"  # :nodoc:

          def declared(program)
            program.each.filter_map do |node|
              node.name if node.kind == :func && node.name.to_s.start_with?(PREFIX)
            end
          end

          def called?(program, routine)
            program.each.any? { |node| node.kind == :call && node.target == routine }
          end

          def message_for(routine)
            picture = routine.to_s.delete_prefix(PREFIX)
            "This game declares `redraw_on_change(:#{picture})`, but it never draws that " \
              "picture. The block says what to draw. A call to `draw` on the handle is " \
              "what puts it on screen. With no such call the picture never appears. To " \
              "fix this, call `#{picture}.draw` in the frame, where the picture belongs " \
              "in the drawing order."
          end
        end

        # Down here because the check classes it names are declared above it.
        CHECKS = Ractor.make_shareable([NeverDrawn.new])  # :nodoc:
      end
    end
  end
end
