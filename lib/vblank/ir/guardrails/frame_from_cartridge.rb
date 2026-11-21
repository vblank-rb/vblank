# frozen_string_literal: true

require VBlank.root.join("lib/vblank/messages/plain_words").to_s

module VBlank
  module IR
    module Guardrails
      module Checks
        # A warning that the code of the `game_loop` did not fit in the console's quick memory,
        # so it runs from the cartridge, which is slower. Where the build did not measure the
        # game:
        #
        # > The game loop's body did not fit in the console's quick memory. It needs <size>,
        # > and <size> was free when its turn came. So the whole frame runs from the
        # > cartridge, at about two and a half times slower than it could. The cause is not
        # > the work the loop does. The cause is how much code is in it. The usual cause is a
        # > large piece of code in the loop that seldom runs. To fix this, move that code into
        # > a `func` of its own, and mark it `fast: false`. Then the loop is small enough to
        # > fit, and the rare code runs from the cartridge only when it runs. To see what was
        # > kept in the quick memory and what was not, call `rom.profile` on the built ROM.
        #
        # Where the build measured the game, the middle of the message says how much of a
        # frame's work the loop's own code does, and gives two ways out:
        #
        # > So the loop's own code runs from the cartridge, at about two and a half times
        # > slower than it could. <In the :name scene, where a frame does the most work,
        # > that> code is about <number>% of the work of a frame. To fix this, make the loop's
        # > body smaller: move code that seldom runs into a `func` of its own, and mark it
        # > `fast: false`. Or give the loop more room: mark a routine that matters less
        # > `fast: false`, or remove `fast: true` from a routine, a scene or a `save_data`
        # > record that matters less.
        #
        # This one is hard to find without the warning. The game slows down evenly, in code
        # the author did not touch, and taking out the new code that pushed the loop over
        # makes it fast again, so the new code looks like the cost. It is not: its size is.
        # Moving the seldom-run part into a `func` marked `fast: false` is the fix. A loop's
        # code that does little of a frame's work is not warned about.
        #
        #--
        # The game loop's body is the single most valuable thing to keep in the console's
        # quick memory — it is where nearly all of a frame's time goes, and code there runs
        # about two and a half times faster than code fetched from the cartridge. The build
        # offers it the memory first, after only what the author insisted on (`fast: true`).
        # When it does not fit, the whole frame runs from the
        # cartridge, and the game is slower by that factor for a reason nothing else in a
        # build can show.
        #
        # Why this one needs saying out loud: everything about it points the wrong way. A game
        # that gives many enemies a few dozen statements of thinking each frame can make the
        # loop's body too big to fit, and then the loop is left in the cartridge and every
        # part of the frame's work runs from there: the frame takes more than twice as long.
        # None of it is the work. Taking the thinking out puts the frame straight back, and
        # taking any one part of it out changes nothing. The symptom is a slowdown spread
        # evenly over code the author did not touch; bisecting by removing the new work finds
        # nothing, because the new work is not the cost, its presence is; and the instinct to
        # optimise what was just added is exactly wrong. The fix is one word — put the
        # thinking in a routine of its own, marked `fast: false` — and that is what the
        # message says.
        #
        # The chooser records what it passed over (see Backends::GBA::QuickMemoryPlan), so this
        # only has to read it. A build with no chooser at all (`fast_code: false`) passes
        # nothing over and says nothing.
        #
        # A loop left out is not always a frame slowed, and a build that measured its game can
        # tell the two apart. The story above is a loop whose body holds the frame's work in
        # line. A loop that only picks a scene and calls it holds almost none: the work is in
        # the routines it calls, each placed on its own, and when those take the room the loop
        # is left in the cartridge at the cost of the few instructions that are its own. Said
        # of that game, "the whole frame runs from the cartridge" is not true, and the advice
        # sends its author looking for code to move out of a loop that has none.
        #
        # So where the build measured the game, the warning is given only when the loop's own
        # code did a real part of a frame's work, and it says how much, and in which scene: the
        # one whose frames do the most, which is the figure `rom.profile` prints for that scene
        # (see Diagnostics::RoutineProfile::Busiest). The loop may then have missed its place
        # because costlier routines went first, or what the author insisted on, so the advice
        # names both ways out, a smaller loop or more room for it. Where nothing was measured
        # the loop was offered the memory first after what the author insisted on and missed it
        # on size, which is the case above, and nothing better is known than what that warning
        # says.
        #++
        class FrameFromCartridge
          NAME = :frame_from_cartridge
          PLAIN_NAME = "the game loop running from the cartridge"

          # The part of the busiest scene's work, in per cent, the loop's own code has to do
          # before leaving it in the cartridge is worth a warning. Code there takes about two
          # and a half times as long, so a loop doing a tenth of a frame's work adds about a
          # seventh to it by being left out, at the most, and one doing less adds less.
          LEAST_SHARE_WORTH_WARNING = 10

          # What both warnings say of code left in the cartridge.
          SLOWER = "at about two and a half times slower than it could"

          def initialize(placement)
            @placement = placement
          end

          def detect(program)
            frame = Cartridge::BuildRecord::FRAME_ROUTINE
            over = @placement&.passed_over&.find { |o| o.name == frame } or return []
            return [] if over.measured && over.measured.percent < LEAST_SHARE_WORTH_WARNING

            loop_node = program.children.find { |node| node.kind == :loop } or return []

            [Finding.new(check: NAME, severity: :warning, message: message(over), node: loop_node)]
          end

          private

          def message(over)
            "The game loop's body did not fit in the console's #{Messages::PlainWords::QUICK_MEMORY}. It needs " \
              "#{kilobytes(over.bytes)}, and #{kilobytes(over.room)} was free when its turn came. " \
              "#{over.measured ? measured_message(over.measured) : unmeasured_message} To see what was kept in the " \
              "#{Messages::PlainWords::QUICK_MEMORY} and what was not, call `rom.profile` on the built ROM."
          end

          # Nothing was measured: the loop is taken to be where the frame's work is.
          def unmeasured_message
            "So the whole frame runs from the cartridge, #{SLOWER}. The cause is not the work the loop " \
              "does. The cause is how much code is in it. The usual cause is a large piece of code in the " \
              "loop that seldom runs. To fix this, move that code into a `func` of its own, and mark it " \
              "`fast: false`. Then the loop is small enough to fit, and the rare code runs from the " \
              "cartridge only when it runs."
          end

          # The game was measured: say what the loop's own code was of a frame, and both fixes.
          def measured_message(measured)
            where = measured.scene ? "In the #{measured.scene.inspect} scene, where a frame does the most work, that" : "That"
            "So the loop's own code runs from the cartridge, #{SLOWER}. #{where} code is about " \
              "#{measured.percent.round}% of the work of a frame. To fix this, make the loop's body smaller: " \
              "move code that seldom runs into a `func` of its own, and mark it `fast: false`. Or give the " \
              "loop more room: mark a routine that matters less `fast: false`, or remove `fast: true` from a " \
              "routine, a scene or a `save_data` record that matters less."
          end

          def kilobytes(bytes) = format("%.1fK", bytes / 1024.0)
        end
      end
    end
  end
end
