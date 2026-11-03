# frozen_string_literal: true

module VBlank
  module IR
    # HOW MANY FRAMES A PASS OF THE GAME LOOP TOOK, as a contract every backend keeps.
    #
    # A game loop waits for the screen, does its work, and comes round again. While the work fits
    # in the time between two frames, one pass IS one frame and nothing has to be counted. When
    # the work does not fit, a pass spans two frames or three — and anything that was counting
    # passes and calling them frames is counting the wrong thing.
    #
    # The names live here rather than in a backend because the question is not about any one
    # machine. A target that shows frames can answer it; how it knows is its own business (one
    # reads the screen's own interrupt, another simply knows it is never late).
    module Frames
      # Frames since the program started.
      COUNT = :__frames

      # What that was at the top of the last pass, and the difference between then and now — how
      # many frames the pass that just ended has to answer for. One, on a program that keeps up.
      SEEN = :__frames_seen
      STEP = :__frame_step

      # THE MOST A SINGLE PASS MAY ANSWER FOR. A pass that took half a second is a loading
      # screen, a first frame, or a hitch — and whatever reads this would then be asked to do
      # thirty frames of catching up inside one already-late pass, which is how a slow program
      # talks itself into being a stopped one.
      #
      # Capped HERE and not in each thing that reads it, which is the whole point of the cap
      # living with the number. Ten is the original Wolfenstein's own limit (MAXTICS) and it is a
      # sixth of a second — long enough that no ordinary pass reaches it.
      MOST = 10

      # Does +program+ read how many frames have gone by, so that the same buttons on the same pass
      # can give another game on a machine that takes longer over a pass?
      def self.reads_frame_clock?(program)
        program.walk.any? { |node| node.kind == :var_ref && [COUNT, SEEN, STEP].include?(node.name) }
      end

      # Is the only wait for the screen in +program+ the one at the top of its game loop, so that a
      # wait and a pass are the same thing?
      def self.waits_only_at_loop_top?(program)
        waits = program.walk.select { |node| node.kind == :wait_vblank }
        loop_node = program.walk.find { |node| node.kind == :loop }
        waits.one? && !loop_node.nil? && loop_node.children.first.equal?(waits.first)
      end

      # WHAT A GAME LOOP PLACES AT THE FRAME BOUNDARY FOR THE DISPLAY, which the builder puts in the
      # gap after the loop's wait among the rest it does there: where each background it moves
      # sits, the top of each status bar, the map and the colours each background was handed, how
      # each turning one is turned, the tiles and sprite lists painted since, and the frame's
      # sprites — each write held to its scene's turn, or to a change, by an `if`. The builder
      # moves every such write out of the game's own lines to put it there, so a statement of the
      # loop holding one of these is one of the boundary's.
      PLACED_AT_BOUNDARY = %i[scroll_background place_bar show_map background_colors affine_background
                              copy_owed_tiles color_list_holds see_through present_objects].freeze

      # ...and the routines that do such a write for it: putting the frame's sprites in order (a
      # pool's things, a `draw_in_order`) and copying the tiles painted since, which a walk of the
      # loop's own statements sees only as a call. They go by the kind of name the builder makes for
      # each (Messages::MadeNames).
      BOUNDARY_ROUTINES = %i[pool_stacking draw_order painted_copies].freeze

      # Is +statement+ one of the boundary's writes for the display (PLACED_AT_BOUNDARY,
      # BOUNDARY_ROUTINES)?
      def self.placed_at_boundary?(statement)
        statement.walk.any? do |node|
          PLACED_AT_BOUNDARY.include?(node.kind) ||
            (node.kind == :call && BOUNDARY_ROUTINES.include?(Messages::MadeNames.read(node.target)&.first))
        end
      end

      # A game loop as a console runs it: +before+, what runs once before the loop; +each_time+,
      # what the loop runs each time round; +placed+, the boundary's writes among those, which a
      # pass that put a background up does not let move that background off its corner
      # (Reference#put_up_background) — the frame it was put up for shows it from there; and
      # +variables+, the ones it keeps of its own (#loop_in_console_order).
      #
      # +pass_end+ is what ends each pass before its wait, which a pass that halts runs first too:
      # the game's last picture is placed as any pass's is.
      ConsoleLoop = Data.define(:before, :each_time, :placed, :variables, :pass_end) do
        def placed?(node) = placed.any? { |write| write.equal?(node) }
      end

      # A game loop's +statements+ in the order +console+ (a Console::Description) runs them (see
      # ConsoleLoop). On a console that sends its sprites and scroll from a copy as the wait ends
      # (Description#sprites_placed_before_wait), each pass ends by placing what is placed at the
      # boundary and then waits, so the frame after the wait shows the pass that just ended — as
      # one that writes them straight in after the wait shows it. The first wait, at power-on,
      # comes before any pass, so it has nothing to place and runs once before the loop. Every
      # backend that runs such a console, the interpreter included, takes the loop in this order.
      #
      # THE FRAME SHOWS THE SCENE THE PASS RAN. What a scene owns is placed while its scene is up,
      # which the builder writes as a test of the game's scene number (Builder#scene_up). A scene
      # that hands over sets that number as it runs, and the next scene comes up in the next pass;
      # so at the end of the pass the number already names the next scene, while the frame still
      # shows this one. So each scene dispatch of the loop notes the number it read, and the
      # boundary's writes are placed with the number put back to that for as long as they run.
      #
      # A SCENE HANDED OVER DEEPER IN THE LOOP, inside an `if`, has its number noted as the pass
      # starts instead, since nothing can be put in beside it.
      #
      # A WAIT THE GAME WRITES PARTWAY DOWN ITS LOOP splits the pass there: what comes before it is
      # the pass that shows after it, so the boundary's writes go in just before it. A wait written
      # deeper than the loop's own statements, in a scene or an `if`, stays as written, and what it
      # places shows a frame later (Console::ColorAnswers says so).
      #
      # A LOOP ENTERED FROM INSIDE ANOTHER PASS (+nested+) places before its first wait, which ends
      # that pass. A loop at the top of the program has nothing before it to place.
      def self.loop_in_console_order(statements, console, nested: false)
        as_written = ConsoleLoop.new(before: [], each_time: statements, placed: [], variables: [], pass_end: [])
        return as_written unless console.sprites_placed_before_wait

        wait_at = statements.index { |node| node.kind == :wait_vblank }
        return as_written if wait_at.nil?

        wait = statements[wait_at]
        placed, body = statements.reject { |node| node.equal?(wait) }.partition { |node| placed_at_boundary?(node) }
        return as_written if placed.empty?

        ahead = statements.first(wait_at)
        top_level = body.select { |node| scene_dispatch?(node) }
        deeper = body.flat_map { |node| dispatches_inside(node) }.reject { |node| top_level.any? { |top| top.equal?(node) } }
        scene_numbers = (top_level + deeper).map(&:var).uniq
        read = ->(number) { :"__scene_read_#{number}" }
        held = ->(number) { :"__scene_held_#{number}" }
        note = ->(number) { Build.set(read.call(number), Build.var_ref(number)) }
        noted = ->(nodes) { nodes.flat_map { |node| scene_dispatch?(node) ? [note.call(node.var), node] : [node] } }
        put_back = scene_numbers.flat_map do |number|
          [Build.set(held.call(number), Build.var_ref(number)), Build.set(number, Build.var_ref(read.call(number)))]
        end
        restored = scene_numbers.map { |number| Build.set(number, Build.var_ref(held.call(number))) }
        pass_end = [*put_back, *placed, *restored]
        variables = scene_numbers.flat_map { |number| [read.call(number), held.call(number)] }
        noted_at_start = deeper.map(&:var).uniq.map(&note)
        if wait_at.zero?
          first_wait = nested ? [*scene_numbers.map(&note), *pass_end, wait] : [wait]
          return ConsoleLoop.new(before: first_wait, each_time: [*noted_at_start, *noted.call(body), *pass_end, wait],
                                 placed: placed, pass_end: pass_end, variables: variables)
        end

        written_ahead, written_after = body.partition { |node| ahead.any? { |early| early.equal?(node) } }
        ConsoleLoop.new(before: [], each_time: [*noted_at_start, *noted.call(written_ahead), *pass_end, wait, *noted.call(written_after)],
                        placed: placed, pass_end: pass_end, variables: variables)
      end

      # A game loop's order, knowing whether +node+ runs inside another pass: in another loop, or in
      # a routine or scene one calls.
      def self.console_order_of(node, console)
        loop_in_console_order(node.children, console, nested: nested_in_pass?(node))
      end

      def self.nested_in_pass?(node)
        at = node.parent
        at = at.parent until at.nil? || %i[loop func].include?(at.kind)
        !at.nil?
      end

      # A `case` that hands the screen to a scene: one whose clauses call scenes. A game's own
      # dispatch on a number of its own is left as it is.
      def self.scene_dispatch?(node) = node.kind == :case && node.clauses.any? { |_, target| Modes.scene_func?(target) }

      # Every scene dispatch under +statement+, or +statement+ itself, short of a loop of its own.
      def self.dispatches_inside(statement)
        return [] if statement.kind == :loop

        [(statement if scene_dispatch?(statement)), *statement.children.flat_map { |child| dispatches_inside(child) }].compact
      end

      # THE STATEMENTS A BEAT MEANS — `every` and `after` (Reference#exec_every, #exec_after) —
      # said as the plain ones every lowering already makes, so none of them writes the rule
      # again. The beat's counter moves on by the frames the pass answers for, and at least one:
      # before the first frame has ended nothing has been counted yet, and that pass is a frame.
      #
      # A repeating beat takes its period off rather than starting again from nought, so one
      # that overshoots keeps the remainder. A one-shot fires when its count is REACHED rather
      # than landed on, because a pass worth two frames can step over the frame it waited for,
      # and stops counting once it has fired, so it never fires twice.
      def self.beat_statements(node)
        frames = Build.clamped(Build.var_ref(STEP), Build.int(1), Build.int(Int32::MAX))
        counter = Build.var_ref(node.counter)
        case node.kind
        when :every
          reached = Build.binop(:>=, counter, Build.int(node.period))
          [Build.add(node.counter, frames), Build.if_(reached, Build.sub(node.counter, node.period), *node.children)]
        when :after
          fires = Build.if_(Build.binop(:>=, counter, Build.int(node.frames)), *node.children)
          [Build.if_(Build.binop(:<, counter, Build.int(node.frames)), Build.add(node.counter, frames), fires)]
        else
          raise ArgumentError, "#{node.kind.inspect} is not a beat"
        end
      end
    end
  end
end
