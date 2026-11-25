# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A routine too big for the quick memory, cut into pieces that fit.
        #
        # The quick memory runs code more than twice as fast as the cartridge, and a routine goes in
        # whole or not at all (see {Placement}). A game's play screen grows past the room, and then
        # all of it runs from the cartridge, though most of its time is usually spent in a small part
        # of it. Another kind of instruction would help the cartridge less: an ARM instruction there
        # is two fetches over the cartridge's 16-bit bus and a Thumb one is one (GBATEK, "GBA Memory
        # Map", the waitstate table), which is why the console's own games keep their cartridge code
        # in Thumb, but the quick memory's 32-bit bus has no wait at all, and Thumb needs more
        # instructions for the same work. So the build moves the busy part of a big routine there.
        #
        # This is not Backends::RoutineCuts, which cuts a routine too big for a cartridge bank into
        # parts run one after another, each a bank's worth, wherever it can be cut. Here the cut is
        # at statements that can run as a routine of their own, and only where it lets the busy
        # part in.
        #
        # What is cut is a statement written straight in the routine, in a test's either branch,
        # however many tests deep, or in the body of a counted loop. Such a statement made a routine
        # of its own and called from where it was does exactly what it did, because nothing the
        # routine holds in a register lives across its statements: a test is decided before its
        # branch runs, and every number is in memory. A counted loop is the one place that keeps a
        # number in a register (its count, see LoopForm), and a call in its body is what makes it
        # keep the count in its own variable instead, so a piece cut from its body is safe too. A
        # statement that leaves a loop around it (`break`, `next`) is not cut, since a routine of
        # its own cannot leave a loop it is not in. A statement under an `every`, an `after` or an
        # `inside` is never cut, since those keep what the statements inside them work with (the
        # edges a shape clips against) where a routine of its own would not see it. Nor is one
        # holding a declaration, which belongs to where it is written.
        #
        # Which routines, and which pieces. A routine is cut only when the plan passed it over, so a
        # routine that fits keeps its one call and runs as it did. Its statements are taken from the
        # top: one at most half as big as the room the quick memory has with nothing moved is a
        # piece, a test bigger than that is cut inside its branches, and a statement smaller than
        # SMALLEST_PIECE_BYTES stays, since a call costs more than such a piece saves. A counted
        # loop is a piece of any size up to the whole room, since its body runs many times a call;
        # one bigger than the room is cut inside its body (#loop_places). The pieces
        # are then routines like any other, weighed by what a frame spends in each (see
        # Placement#choose_fast_funcs), so the busy one goes in and the rest stay in the cartridge.
        #
        # The names are the places, so they survive a rebuild: a measurement saved from one build is
        # read by routine name (Diagnostics::RoutineProfile), and a piece named by where it is in
        # its routine is the same piece in the next build of the same game. A build cut where the
        # one measured was not finds its pieces unmeasured, and they go after every measured
        # routine, as a routine new since the measuring does. A game changed since its measurement
        # can move a piece to another place, and then the measurement credits the piece now there;
        # measuring again puts it right, as it does for any routine that changed.
        module RoutinePieces
          # Below this a statement stays in its routine. The call to a piece and its return cost
          # four instructions each time, and a piece costs its routine's room besides: four or
          # more instructions for the call, and twelve to twenty bytes more where it crosses
          # between the two memories (Placement::CROSS_CALL_GROWTH). A statement of a hundred and
          # twenty-eight instructions or more pays for both many times over when it runs; one much
          # smaller hands the plan many tiny routines that each save little.
          SMALLEST_PIECE_BYTES = 512

          module_function

          # +program+ with each of +routines+ (names) cut into pieces at most half of +room+ (a
          # counted loop, the whole of it), as a new written program; or nil when there is nothing
          # to cut. +bytes_of+ answers the bytes a statement came to in a measuring pass, nested
          # statements included, or nil for one that pass never lowered.
          def cut(program, routines:, room:, &bytes_of)
            most = room / 2
            cuts = program.walk.select { |node| cuttable_routine?(node) && routines.include?(node.name) }
                          .to_h { |func| [func.name, places_of_pieces(func.children, [], most, room, &bytes_of)] }
                          .reject { |_, places| places.empty? }
            cuts.empty? ? nil : with_pieces(program, cuts)
          end

          # The name of the piece at +place+ in routine +routine+: the indexes down to it, with which
          # branch of each test between ("3_else_0").
          def piece_name(routine, place) = Messages::MadeNames.make(:routine_piece, place: place.join("_"), routine: routine)

          # A routine the build may cut: one the author wrote and left to the build to place. One
          # the author placed (`fast:` either way) goes where they said, whole. A name starting with
          # two underscores is the framework's own (every MadeNames kind, and the routines the
          # builder writes for itself, such as a song's fade), which no author's name can be.
          def cuttable_routine?(node)
            node.kind == :func && node.fast.nil? && !node.on_chip && !node.name.to_s.start_with?("__")
          end

          # Where the pieces are among +statements+, each as the path to it below +above+. A test
          # with no other branch keeps its test and gives up its body (a place ending in :then), so
          # a pass whose test fails does not call the piece only to find that out.
          #
          # A counted loop is cut whole up to the whole +room+, not half of it, and whatever its size:
          # its body runs many times a call, so the call is paid for however few lines it has, and
          # what a loop holds that never runs goes in the quick memory with it, where a loop left in
          # its routine runs from the cartridge. A test holding a loop is looked into whatever its
          # size, for the loop.
          def places_of_pieces(statements, above, most, room, &bytes_of)
            statements.each_with_index.flat_map do |node, at|
              place = above + [at]
              bytes = bytes_of.call(node).to_i
              next [] unless movable?(node)
              next loop_places(node, place, bytes, most, room, &bytes_of) if node.kind == :repeat

              next [] if bytes < SMALLEST_PIECE_BYTES && !(node.kind == :if && holds_loop?(node))
              next [node.kind == :if && node.else.nil? ? place + [:then] : place] if bytes <= most && bytes >= SMALLEST_PIECE_BYTES
              next [] unless node.kind == :if

              places_of_pieces(node.children, place + [:then], most, room, &bytes_of) +
                (node.else ? places_of_pieces(node.else.children, place + [:else], most, room, &bytes_of) : [])
            end
          end

          # The places in the counted loop +node+, at +place+ and +bytes+ big: the loop itself where it
          # fits the whole room. A loop bigger than that stays in its routine and gives up the big
          # statements of its body, each a piece called from every turn, so the loop counts in its own
          # index variable (a call in a body takes the loop out of the registers, see LoopForm) and the
          # busy lines in it stay in the routine. A statement that leaves the loop (`break`, `next`)
          # is not given up, since a routine of its own cannot leave a loop it is not in.
          def loop_places(node, place, bytes, most, room, &bytes_of)
            return [place] if bytes.positive? && bytes <= room

            places_of_pieces(node.children, place + [:loop], most, room, &bytes_of)
          end

          # Does the test +node+ have a counted loop written straight in one of its branches, however
          # many tests deep?
          def holds_loop?(node)
            branches = [node, node.else].compact
            branches.any? { |branch| branch.children.any? { |child| child.kind == :repeat || (child.kind == :if && holds_loop?(child)) } }
          end

          # A statement that does the same as a routine of its own: not a declaration, and holding
          # none, nor any of the author's own instructions (`entry`'s raw ARM), which can read a
          # register a statement before it left.
          def movable?(node)
            node.statement? && node.each.none? { |inside| inside.class.role == :declaration || inside.kind == :raw } &&
              !leaves_loop?(node)
          end

          # Does +node+ hold a `break` or `next` of a loop that is not inside it?
          def leaves_loop?(node, depth = 0)
            return depth.zero? if %i[break_repeat next_repeat].include?(node.kind)

            inside = node.kind == :repeat ? depth + 1 : depth
            node.children.any? { |child| leaves_loop?(child, inside) } || (node.kind == :if && node.else && leaves_loop?(node.else, inside))
          end

          # A copy of +program+ with each place of +cuts+ (routine name to the places of its pieces)
          # made a routine of its own, called from where it was.
          def with_pieces(program, cuts)
            fresh = program.copy
            routines = fresh.walk.select { |node| node.kind == :func }.to_h { |node| [node.name, node] }
            pieces = cuts.flat_map do |routine, places|
              places.map { |place| piece_at(routines.fetch(routine), routine, place) }
            end
            pieces.each { |piece| fresh.add_child(piece) }
            fresh.mark_written!
          end

          # The statement at +place+ in +func+ taken out as a routine, with a call to it left where
          # it was; or, for a place ending in :then, the body of the test there, the call left as
          # the test's body.
          def piece_at(func, routine, place)
            body = place.last == :then
            path = body ? place[0...-1] : place
            owner = func
            path[0...-1].each_slice(2) do |at, branch|
              test = owner.children.fetch(at)
              owner = branch == :else ? test.else : test
            end
            statement = owner.children.fetch(path.last)
            name = piece_name(routine, place)
            call = Build.call(name)
            call.source = statement.source
            piece = if body
                      moved = statement.children.dup
                      statement.children.replace([call])
                      call.parent = statement
                      Build.func(name, *moved)
                    else
                      owner.children[path.last] = call
                      call.parent = owner
                      Build.func(name, statement)
                    end
            piece.source = statement.source
            piece
          end
        end
      end
    end
  end
end
