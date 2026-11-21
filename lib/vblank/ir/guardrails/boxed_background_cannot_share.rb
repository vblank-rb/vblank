# frozen_string_literal: true

require VBlank.root.join("lib/vblank/ir/stacking").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # An error for a background held to a box with `show_only_inside`, beside a second such
        # background on the same screen:
        #
        # > The backgrounds :<name> and :<name> are on the screen at the same time, and the game
        # > holds both to a box with show_only_inside. One screen can hold one background to a box.
        #
        # To fix this, put the two backgrounds in different scenes, or hold only one of them to a
        # box.
        #
        # On a console whose box shares the display's windows with a light, a status bar and a fade
        # held to part of the screen or under a layer, a game with a box can have none of those:
        #
        # > This game holds the background :<name> to a box with show_only_inside, and has <what>.
        # > On the <console>, both need the same windows of the display, and the windows can do only
        # > one of the two. To fix this, remove show_only_inside, or remove <what>.
        #
        # The console cannot do both, so one of them would show wrong. The build stops on every
        # backend in the same words.
        #
        #--
        # A background held to a box (`show_only_inside`) beside something that needs the same part
        # of the display, or beside a second one on the same screen.
        #
        # A console holds a layer to a box with a window: a rectangle of the screen the display is
        # told about, with a switch for each layer saying whether it is drawn inside the rectangle
        # and another for outside it. The display looks the switches up for every pixel as it draws,
        # so nothing is drawn and then hidden, and what is behind the layer shows where it is off.
        #
        # One window is one box, so two backgrounds held to boxes on one screen are refused.
        #
        # On the Advance the display has two windows and one set of switches for "outside every
        # window". The light, a status bar and a fade held to part of the screen or put under a
        # layer each set those switches too, and the one window left over cannot hold the box: where
        # the two windows cross, the first one's switches win, so the boxed layer would show inside
        # the light whatever its box set. So a game with a box does none of them, anywhere in it.
        #
        # Asked of the console the program is built for (Console::Description#background_box), so
        # the interpreter refuses what the cartridge would get wrong, in the same words.
        #++
        class BoxedBackgroundCannotShare
          NAME = :boxed_background_cannot_share
          PLAIN_NAME = "a background held to a box beside something that needs the same part of the display"

          def detect(program)
            # A line that only ever shows a background everywhere (held 0, written in the program)
            # asks for no window, and nor does one that only hides it whole (`hide`), which a
            # console switches off as a layer.
            boxes = program.walk.select { |node| node.kind == :box_background && node.in_part? }
            return [] if boxes.empty?

            found = two_on_one_screen(program, boxes.map(&:name).uniq) ||
                    (window_sharing(program, boxes.first) if program.described_console.background_box == :shared_windows)
            found ? [found] : []
          end

          # Why the box is refused, or nil when it fits: the words the interpreter and each lowering
          # stop with too.
          def refusal_message(program)
            detect(program).first&.message
          end

          private

          def two_on_one_screen(program, names)
            Stacking.screenfuls(program).each do |screenful|
              boxed = screenful.scenery.select { |node| names.include?(node.name) }.map(&:name).uniq
              next if boxed.length < 2

              node = screenful.scenery.find { |each| each.name == boxed.last }
              return refusal(node, "The backgrounds :#{boxed[0]} and :#{boxed[1]} are on the screen at the same time, " \
                                   "and the game holds both to a box with show_only_inside. One screen can hold one " \
                                   "background to a box. To fix this, put the two backgrounds in different scenes, or " \
                                   "hold only one of them to a box.")
            end
            nil
          end

          def window_sharing(program, box)
            other = program.walk.find do |node|
              node.kind == :shade_outside || (node.kind == :fade && (node.under || node.reaches)) ||
                (node.kind == :background && node.bar?)
            end
            return unless other

            what = if other.kind == :shade_outside then "a light (a `spotlight` or an `iris_out`)"
                   elsif other.kind == :background then "the status bar :#{other.name}"
                   elsif other.under then "a fade under the layer :#{other.under}"
                   else "a fade held to part of the screen"
                   end
            console = program.described_console
            refusal(box, "This game holds the background :#{box.name} to a box with show_only_inside, and has " \
                         "#{what}. On the #{console.title}, both need the same windows of the display, and the " \
                         "windows can do only one of the two. To fix this, remove show_only_inside, or remove #{what}.")
          end

          def refusal(node, message) = Finding.new(check: NAME, severity: :error, node: node, message: message)
        end
      end
    end
  end
end
