# frozen_string_literal: true

module VBlank
  module Diagnostics
    # Which lines of a routine its time went to, for any routine, wherever it runs from.
    #
    # A profile says which routines a frame spent its time in. When one of them is most of a slow
    # pass, the next question is which of its lines, and nothing at the routine's level can answer
    # it. SplitHints answers it only for a routine the quick memory passed over, and only to name
    # the part worth a `func`; this answers it for whichever routine the author asks about.
    #
    # The build keeps where each statement's code is in its routine and the line that wrote it
    # (Cartridge::BuildRecord#routine_statements); the run measures how long the console spent at
    # each address. Nothing is added to the cartridge: the console runs the same bytes whether or
    # not anybody asks.
    #
    # Each address is counted once, to the innermost statement round it. A block's line keeps only
    # the code that is its own — the test of an `if`, the count of a `repeat` — and the statements
    # inside it have their own lines, so the lines of a routine add up to the routine. A line that
    # calls a routine holds only the call: the routine called has lines of its own. The code that
    # is no statement's, the routine's entry and return, is said apart.
    #
    # A piece cut from a routine (IR::Backends::GBA::RoutinePieces) is the routine's own code moved
    # to where it runs faster, so its lines are counted in the routine it was cut from, under the
    # lines the author wrote: a piece is never a routine of its own here.
    module RoutineLines
      # One routine's time by line: +routine+ is its name, +frame_share+ its part of every frame
      # measured, in per cent, +lines+ its lines (Line), busiest first, and +outside_lines_share+
      # the part of its time in code that is no statement's: entering and leaving it.
      Routine = Data.define(:routine, :frame_share, :lines, :outside_lines_share)

      # One line of a routine: the line that wrote it ("game.rb:12"), its part of the routine's time
      # and of every frame's, in per cent, and how many instructions it ran a frame.
      Line = Data.define(:source, :share, :frame_share, :instructions)

      # How many routines `lines: true` gives: the busiest of the frames measured.
      BUSIEST_ROUTINES = 3

      # What an author can call the game loop's routine, which has no name of its own.
      GAME_LOOP = :game_loop

      module_function

      # The lines of each routine +asked+ names, or of the busiest ones for +asked+ true, out of
      # +profile+, a run of +rom+. +routines+ is where each routine ran, as the profile named them.
      def of(profile, rom, asked, routines: rom.built.routines)
        frame = profile.frames * profile.cycles_per_frame
        return [] if frame.zero?

        cycles = SplitHints::CycleTable.new(profile.cycles)
        instructions = SplitHints::CycleTable.new(profile.pc)
        groups = routine_groups(rom.built.routine_statements, routines)
        names = asked == true ? busiest(groups, cycles) : Array(asked).map { |name| routine_named!(groups.keys, name) }
        names.filter_map do |name|
          routine_lines(name, groups.fetch(name), cycles, instructions, frame, profile.frames)
        end
      end

      # The names in +asked+ the game has no routine of are refused before anything is played, so
      # a mistyped name costs nothing. +asked+ true asks for no name.
      def refuse_unknown_routines!(rom, asked)
        return if asked.nil? || asked == true

        known = routine_groups(rom.built.routine_statements, nil).keys
        Array(asked).each { |name| routine_named!(known, name) }
      end

      # Each routine with its statements as addresses, by the routine an author wrote: a piece's
      # statements are its routine's. +routines+ is where each runs; nil answers the names alone.
      def routine_groups(statements, routines)
        statements.each_with_object({}) do |(name, parts), groups|
          routine = Messages::MadeNames.routine_cut_into(name) || name
          group = groups[routine] ||= { spans: [], parts: [] }
          next unless routines

          span = routines[name] or next
          group[:spans] << span
          group[:parts].concat(parts.map { |part| { source: part[:source], at: (span.begin + part[:within].begin)...(span.begin + part[:within].end) } })
        end
      end

      # The routines that took the most time, up to BUSIEST_ROUTINES, leaving out one that took none.
      def busiest(groups, cycles)
        timed = groups.to_h { |name, group| [name, group[:spans].sum { |span| cycles.time_in(span) }] }
        timed.select { |_, time| time.positive? }.max_by(BUSIEST_ROUTINES) { |_, time| time }.map(&:first)
      end

      # The routine +name+ asks for, as the build named it: a `func`'s own name, a scene's name, or
      # :game_loop; refused in plain words where there is none.
      def routine_named!(known, name)
        wanted = name.to_s.delete_prefix(":").to_sym
        found = [wanted, :"_scene_#{wanted}", (IR::Backends::GBA::Placement::FRAME_ROUTINE if wanted == GAME_LOOP)]
                .find { |candidate| candidate && known.include?(candidate) }
        return found if found

        raise ArgumentError, "The game has no routine called :#{wanted}. To see the lines of a routine, give one of " \
                             "these: #{known.filter_map { |routine| name_to_ask(routine) }.sort.join(', ')}."
      end

      # How an author asks for +routine+: a `func` by its name, a scene by the scene's, the game loop
      # as :game_loop. nil for a routine the framework made for itself.
      def name_to_ask(routine)
        return ":#{GAME_LOOP}" if routine == IR::Backends::GBA::Placement::FRAME_ROUTINE
        return nil if routine.to_s.start_with?("__")

        ":#{routine.to_s.delete_prefix('_scene_')}"
      end

      # What a report calls +routine+: a scene as `scene :name`, any other as Messages::PlainWords does.
      def words_for(routine)
        scene = routine.to_s.delete_prefix("_scene_")
        scene == routine.to_s ? Messages::PlainWords.routine(routine) : "scene :#{scene}"
      end

      # One routine's lines (Routine), or nil for one that took no time.
      def routine_lines(name, group, cycles, instructions, frame, frames)
        total = group[:spans].sum { |span| cycles.time_in(span) }
        return nil if total.zero?

        own_time = own_of_each(group[:parts], cycles)
        own_runs = own_of_each(group[:parts], instructions)
        by_line = group[:parts].each_index.group_by { |at| group[:parts][at][:source] }
        lines = by_line.filter_map do |source, ats|
          time = ats.sum { |at| own_time[at] }
          next if time.zero?

          Line.new(source: source, share: percent(time, total), frame_share: percent(time, frame),
                   instructions: (ats.sum { |at| own_runs[at] }.to_f / frames).round)
        end
        Routine.new(routine: name, frame_share: percent(total, frame), lines: lines.sort_by { |line| -line.share },
                    outside_lines_share: percent(total - own_time.sum, total))
      end

      # What each statement of +parts+ took that is its own and not a statement's inside it, out of
      # +counts+ (a SplitHints::CycleTable), in the order of +parts+. Statements are emitted in one
      # go, so any two are one inside the other or apart: a walk in order of where each starts,
      # widest first, finds each one's nearest statement round it.
      def own_of_each(parts, counts)
        whole = parts.map { |part| counts.time_in(part[:at]) }
        own = whole.dup
        round = []
        parts.each_index.sort_by { |at| [parts[at][:at].begin, -parts[at][:at].size] }.each do |at|
          span = parts[at][:at]
          round.pop while round.any? && !(parts[round.last][:at].cover?(span.begin) && span.end <= parts[round.last][:at].end)
          own[round.last] -= whole[at] if round.any?
          round << at
        end
        own
      end

      def percent(part, whole) = whole.zero? ? 0.0 : (100.0 * part / whole).round(1)
    end
  end
end
