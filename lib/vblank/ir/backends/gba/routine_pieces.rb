# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBA
        # A ROUTINE TOO BIG FOR THE QUICK MEMORY, CUT INTO PIECES THAT FIT.
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
        # WHAT IS CUT is a statement the routine runs at most once each time it is called: one
        # written straight in the routine, or in a test's either branch, however many tests deep.
        # Such a statement made a routine of its own and called from where it was does exactly what
        # it did, because nothing the routine holds in a register lives across its statements: a
        # test is decided before its branch runs, and every number is in memory. A statement under a
        # counted loop, an `every`, an `after` or an `inside` is never cut, since those keep what
        # the statements inside them work with (a count in a register, the edges a shape clips
        # against) where a routine of its own would not see it. Nor is one holding a declaration,
        # which belongs to where it is written.
        #
        # WHICH ROUTINES, AND WHICH PIECES. A routine is cut only when the plan passed it over, so a
        # routine that fits keeps its one call and runs as it did. Its statements are taken from the
        # top: one at most half as big as the room the quick memory has with nothing moved is a
        # piece, a test bigger than that is cut inside its branches, and a statement smaller than
        # SMALLEST_PIECE_BYTES stays, since a call costs more than such a piece saves. The pieces
        # are then routines like any other, weighed by what a frame spends in each (see
        # Placement#choose_fast_funcs), so the busy one goes in and the rest stay in the cartridge.
        #
        # THE NAMES ARE THE PLACES, so they survive a rebuild: a measurement saved from one build is
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

          # +program+ with each of +routines+ (names) cut into pieces at most half of +room+, as a
          # new written program; or nil when there is nothing to cut. +bytes_of+ answers the bytes a
          # statement came to in a measuring pass, nested statements included, or nil for one that
          # pass never lowered.
          def cut(program, routines:, room:, &bytes_of)
            most = room / 2
            cuts = program.walk.select { |node| cuttable_routine?(node) && routines.include?(node.name) }
                          .to_h { |func| [func.name, places_of_pieces(func.children, [], most, &bytes_of)] }
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
          def places_of_pieces(statements, above, most, &bytes_of)
            statements.each_with_index.flat_map do |node, at|
              place = above + [at]
              bytes = bytes_of.call(node).to_i
              next [] if bytes < SMALLEST_PIECE_BYTES || !movable?(node)
              next [node.kind == :if && node.else.nil? ? place + [:then] : place] if bytes <= most
              next [] unless node.kind == :if

              places_of_pieces(node.children, place + [:then], most, &bytes_of) +
                (node.else ? places_of_pieces(node.else.children, place + [:else], most, &bytes_of) : [])
            end
          end

          # A statement that does the same as a routine of its own: not a declaration, and holding
          # none, nor any of the author's own instructions (`entry`'s raw ARM), which can read a
          # register a statement before it left.
          def movable?(node)
            node.statement? && node.each.none? { |inside| inside.node_class.role == :declaration || inside.kind == :raw }
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
