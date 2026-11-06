# frozen_string_literal: true

module VBlank
  module Playthroughs
    # TWO CARTRIDGES PLAYED SIDE BY SIDE ON THE SAME PRESSES, and where their pictures stop
    # being the same.
    #
    #   result = walk.compare(ours, theirs)
    #   result.drift?         # did they ever differ?
    #   result.drift.frame    # the first frame they did
    #   result.drift.moment   # the named moment before it
    #
    # WHAT IT IS FOR. Somebody rebuilding an existing game wants to know where their cartridge
    # has drifted from the original; a framework change that moves something a frame early
    # wants catching without two people squinting at two screens. Both are the same question:
    # given the same game to play, on which frame do these two first show something different?
    #
    # THE SAME PRESSES ON THE SAME FRAMES. What is compared is a tape: which buttons were down
    # on each frame. A script is played on the first cartridge alone to make one, so where the
    # script watches the game — "walk right until the door" — it is the first cartridge it
    # watched, and the second is handed exactly the walk the first one took. That is the
    # strict comparison: a second cartridge whose door is a frame further off is still walking
    # when the first has stopped, and the two differ from that frame on.
    #
    # EVERY PIXEL OF EVERY FRAME, unless told how alike is alike enough (see Likeness), and it
    # stops at the first drift unless it is told to carry on. One frame out is nearly always
    # every frame after it out too, so the first is the one worth having — and where it is
    # not, `carrying_on: true` plays to the end and `result.drifts` lists every stretch of
    # drift, which says whether the two came back into step.
    #
    # OR THE SAME SCRIPT ON EACH, asked for with `same: :script`: each cartridge played by
    # the script on its own, and the two compared at each named moment (see AtMoments).
    # That forgives timing, and finds a game that looks different where the same tape finds
    # one that is a frame late.
    #
    # AND NAMED READINGS, where it is given any: numbers read off both running cartridges
    # after every frame, each its own way (see Readings). Which of the two is compared —
    # the picture, the readings, or both — is a list said where the comparison is made (see
    # Compared).
    #
    # OR LINED UP BY THE GAME'S OWN PASSES, asked for with `by_passes:`: each cartridge says its
    # count of passes, and the two are compared on the first frame each shows each pass, so a
    # pass that takes two frames on one and one on the other is still like with like (see
    # Passes). Or with each cartridge's own still frames skipped, asked for with
    # `skipping_still_frames_of:`, so a room that loads for longer on one is in step again after
    # (see StillFrames).
    #
    # AND ONE FRAME OF THE TWO AS A PICTURE, for a person to look at: the two screens side by
    # side with what differs marked (see ScreenPair). A report of a drift holds one, and one
    # can be asked for by itself, of any frame (see PictureRequest).
    #
    # +first+ and +second+ are the two cartridges.
    class Comparison
      # Where the two stopped being alike: the first frame of a stretch of differing frames
      # long enough to count. +moment+ is the last moment named before that frame was played,
      # for a person to place the frame by: nil when none had been. A moment that names the
      # very frame is not before it.
      #
      # (A comparison on the same script has no frame the two share, and finds its drifts
      # AT moments. There +moment+ is the moment the two differed at, +frame+ the frame the
      # first cartridge reached it on, and a drift has no last frame, being one point.) +differed+ is what differed for long enough to count
      # while the drift lasted, in the order each began to: `:picture`, and the name of
      # each reading that did. +readings+ is every named reading on both cartridges on the
      # frame it began, whether it differed or not — each name with its pair of values,
      # the first cartridge's and the second's.
      #
      # +last_frame+ is the last frame of the stretch and +ended+ how it ended, for a
      # comparison that carried on: `:back_in_step` when the next frame was one on which
      # the two were within the settings again, `:not_looked_at` when the next frame was
      # one the comparison was told to leave out, and `:tape_ran_out` when it was still
      # going on the last frame of the tape. A comparison that stops at its first drift
      # never finds out how long it lasted, and there both are nil.
      #
      # +report+ is the folder a report of it was written into (see DriftReport), or nil
      # when the comparison was given nowhere to write one.
      #
      # +picture_difference+ is how the pictures differed on the frame it began, where the
      # picture is what differed (Verifier#difference_from: how many pixels, the box they lie in,
      # the first and its colour on each), and nil otherwise and for a drift found at a moment.
      #
      # +video_differences+ is, where the picture is what differed, which of the console's video
      # memories differed between the two on the frame it began, each with its first difference
      # (VideoDifference): the colours, the sprite table, the scroll, the video registers. It is
      # empty otherwise, for a drift found at a moment, and for two cartridges whose pictures
      # differ though none of those does (the pictures the tiles are made of, say).
      #
      # +second_frame+ is, for a comparison lined up step by step (see LinedUp), the frame the
      # second cartridge began it on (+frame+ is the first's, and so is +last_frame+), and +pass+
      # the pass it began on where the steps are passes (see Passes). Both are nil frame by frame.
      Drift = Data.define(:frame, :last_frame, :ended, :moment, :differed, :readings, :report, :picture_difference,
                          :video_differences, :pass, :second_frame) do
        def initialize(frame:, moment:, differed:, readings:, last_frame: nil, ended: nil, report: nil, picture_difference: nil,
                       video_differences: [], pass: nil, second_frame: nil) = super

        # The frames of the stretch as a range, first to last, or nil where the last is
        # not known.
        def stretch = last_frame && (frame..last_frame)

        # Whether the two came back within the settings after it.
        def back_in_step? = ended == :back_in_step
      end

      # What a comparison found. +frames+ is how many frames were played, and +drifts+ every
      # stretch of drift that was found, in the order they happened: none when the two
      # never differed, and one at most unless the comparison was asked to carry on.
      #
      # +moments+ is the frame each cartridge reached each named moment on: each name with
      # the first cartridge's frame and the second's. On the same tape those are the same
      # frame, and only the moments reached before the comparison stopped are there. On
      # the same script they are how long each took, and +frames+ is the first cartridge's.
      Result = Data.define(:frames, :moments, :drifts) do
        def drift? = drifts.any?

        # Where the two FIRST stopped being alike — nil when they never did.
        def drift = drifts.first
      end

      # What the picture is called wherever what differed is listed, beside the names of
      # the readings — and what a difference in how long the two took to reach a moment is
      # called there, for a comparison on the same script. No reading can have either name.
      PICTURE = :picture
      FRAMES_APART = :frames_apart

      # A READING'S OWN BLOCK STOPPED WITH AN ERROR, part way through the playing. The
      # message says which reading and which cartridge; the block's own error is its cause.
      class ReadingFailed < StandardError; end

      # A DRIFT WAS FOUND AND ITS REPORT COULD NOT BE WRITTEN. The place is looked at before
      # a frame is played, so this is the rare case of a disk that filled, or something that
      # changed while the two were playing. The finding is the part that cost the playing,
      # so the error still holds it: +drift+ is where the two stopped being alike, and
      # +earlier+ the drifts a comparison that carried on had found before that one, whose
      # reports were written.
      class ReportNotWritten < StandardError
        attr_reader :drift, :earlier

        # +where+ is the sentence that says where the drift was, as its report would have.
        def initialize(drift, where, folder, why)
          @drift = drift
          @earlier = []
          super("#{where} The report of that drift could not be written in #{folder}: #{why}. " \
                "Give `reports_in:` the path of a folder that can be written to.")
        end

        # The same error, holding the drifts found before the one it is about.
        def after(earlier) = tap { @earlier = earlier }
      end

      # +moments+ is the names of the moments the playthrough declares, in order: what the
      # script or the tape says they are, and not a setting a caller can give.
      # +ignoring_frames+ is the stretches of it that are not looked at (see IgnoredFrames),
      # and +how_alike+ what a Likeness takes: how alike two pictures have to be. +readings+
      # is the named readings (see Readings) and +comparing+ the list of what is compared
      # (see Compared), nil for nothing said. +carrying_on+ says whether to play on past the
      # first drift and list every stretch of it. +reports_in+ is a folder to write a
      # report of each drift into (see DriftReport), or nil for none. All of it is read
      # here, so a setting that makes no sense is refused before a frame is played.
      #
      # +same+ says how the second cartridge is fed: `:tape`, the same presses on the same
      # frames as the first, or `:script`, the same script playing each by itself (see
      # AtMoments). +frames_apart+ is for the same script only: how many frames apart the
      # two may reach a moment, nil for not checked.
      #
      # +save+ and +lead_ins+ are where the two start, so that they start in step: one
      # save both cartridges hold as their consoles are switched on, and a lead-in for
      # each — a playthrough played on it first and not counted (see
      # Playthrough.power_on_and_lead_in) — the first cartridge's and then the second's,
      # either of them nil for none. +saves+ is a save for each instead, the first
      # cartridge's and then the second's, either nil for none: a port and the original it
      # is made from keep the same moment of the game in saves of their own shapes, which
      # share no bytes.
      #
      # +layers+ is which of the picture is compared: nil for all of it, `:backgrounds` for the
      # picture without its sprites, `:sprites` for the sprites alone (see LAYERS). Or a list of
      # two, one for each cartridge, for a port that draws on other layers than its original:
      # each a list of the layers to keep in the reader's own names (`%i[bg0 bg1]`), the reader's
      # `{ only: }` or `{ without: }`, one of those two words, or nil for all of it.
      # +forgiving_torn_frames_of+ is the cartridge whose torn frames are forgiven where the
      # other already shows what they settle on (see TornFrames), `:first` or `:second`, or nil.
      #
      # +by_passes+ is how each cartridge counts its passes, for two lined up by the game's own
      # passes and not by frames, and +pass_count_wraps_at+ where that count comes back round to
      # nought (see Passes), and +reads_buttons_every_frame+ true for a game that reads its buttons on
      # every frame and not once a pass. +skipping_still_frames_of+ is `:first`, `:second` or `:both`, the
      # cartridges whose frames that show the picture of the frame before are skipped (see
      # StillFrames). Nil for a comparison frame by frame.
      def initialize(first, second, moments, ignoring_frames: [], readings: {}, comparing: nil, carrying_on: false,
                     same: :tape, frames_apart: nil, save: nil, saves: nil, lead_ins: nil, reports_in: nil, layers: nil,
                     forgiving_torn_frames_of: nil, by_passes: nil, pass_count_wraps_at: nil, skipping_still_frames_of: nil,
                     reads_buttons_every_frame: false, **how_alike)
        refuse_unknown_settings!(how_alike.keys)
        passes = Passes.from(by_passes, pass_count_wraps_at, every_frame: reads_buttons_every_frame)
        still_frames = StillFrames.from(skipping_still_frames_of)
        refuse_two_step_counts!(passes, still_frames)
        @step_count = passes || still_frames
        refuse_settings_wrong_for_lined_up!(same: same, torn: forgiving_torn_frames_of, reports_in: reports_in)
        @moments = moments
        @saves = saves_for_each(save, saves)
        refuse_malformed_lead_ins!(lead_ins)
        @lead_ins = lead_ins || [nil, nil]
        @ignored = IgnoredFrames.new(ignoring_frames, moments)
        looked_at = LookedAt.new(**how_alike.slice(*LookedAt::SETTINGS), moments: moments, screen_size: early_screen_size(first))
        @likeness = Likeness.new(**how_alike.slice(*Likeness::SETTINGS), looked_at: looked_at)
        @readings = Readings.new(readings)
        @comparing = comparing
        @compared = Compared.new(comparing, @likeness, @readings)
        refuse_non_boolean_carrying_on!(carrying_on)
        @carrying_on = carrying_on
        @layers = layers
        @shown_layers = shown_layers_for_each(layers)
        @torn_side = forgiving_torn_frames_of
        TornFrames.refuse_unknown_side!(@torn_side)
        @same = same
        @frames_apart = frames_apart
        @reports_in = Report.place_for(reports_in)
        refuse_settings_wrong_for_same!(how_alike)
        @handed_over = [first, second]
      end

      # WHICH OF THE PICTURE `layers:` KEEPS, as the reader's own words for leaving layers out
      # (Diagnostics::Verifier#showing). Every console the comparison lines up calls its sprites
      # `:sprites`, so the two words mean the same on each.
      LAYERS = Ractor.make_shareable({ backgrounds: { without: :sprites }, sprites: { only: :sprites } })

      # Whether each cartridge is played by the script on its own.
      def same_script? = @same == :script

      # Compare the two on +playthrough+, the way that was asked for: its script played on
      # the first cartridge to learn the presses and both then played on those, or its
      # script played on each by itself.
      def run_playthrough(playthrough)
        return run_script(playthrough) if same_script?

        run(starts.first.played_by(playthrough).tape)
      end

      # WHERE ONE OF THE TWO CARTRIDGES STARTS: the cartridge, the save it holds as its
      # console is switched on, and the lead-in played on it first — the save one that
      # fits this cartridge, and a copy of its own. +which+ is `first` or `second`, for an
      # error to say which of the two it was about.
      # +count_passes+ says the console keeps the game loop's count of passes (see Passes).
      Start = Data.define(:which, :cartridge, :save, :lead_in, :count_passes) do
        # A console switched on with the cartridge in it, and led in.
        def console
          saying_which_cartridge do
            Playthrough.power_on_and_lead_in(cartridge, save: save, lead_in: lead_in, count_passes: count_passes)
          end
        end

        # The cartridge played by +playthrough+ from this start.
        def played_by(playthrough, &at_each_moment)
          saying_which_cartridge { playthrough.play(cartridge, save: save, lead_in: lead_in, &at_each_moment) }
        end

        # +tape+ as it is said to start for this cartridge, which is how the tape has to
        # be played to be where the comparison was.
        def tape_said(tape) = tape.started_from(save: save, led_in: !lead_in.nil?)

        # A script that gives up says which of the two cartridges it gave up on: its own
        # error has no way to know there were two.
        private def saying_which_cartridge
          yield
        rescue GaveUp => e
          raise e.exception("On the #{which} cartridge of the comparison: #{e.message}")
        end
      end
      private_constant :Start

      # WHERE THE TWO STARTED, AS SENTENCES, for a report a person reads: nothing at all
      # when both started from power-on with nothing played first.
      private def starting_sentences
        said = []
        said.concat(save_sentences)
        led_in = starts.select(&:lead_in)
        case led_in.size
        when 2 then said << "Each cartridge was led in before frame 1, by these playthroughs: #{led_in.map { |start| start.lead_in.name }.join(', ')}."
        when 1 then said << "The #{led_in.first.which} cartridge was led in before frame 1, by the playthrough #{led_in.first.lead_in.name}."
        end
        said
      end

      # THE TWO CARTRIDGES, each one the build made or a cartridge file read from its path.
      def cartridges = starts.map(&:cartridge)

      # The first cartridge: the one a script is played on alone, to make the tape both are
      # then played on.
      def first = cartridges.first

      # WHERE EACH OF THE TWO STARTS. The cartridges are looked at together, the first time
      # anything is wanted of either, so a second cartridge that is not there is found
      # before the first is played and not after — and after the settings, which need no
      # cartridge to be wrong. What needs a cartridge to be looked at is looked at here
      # too: a reading that is a variable's name, and a save, which has to fit each.
      private def starts
        @starts ||= begin
          pair = @handed_over.map { |given| Playthrough.cartridge_from(given) }
          refuse_cartridges_not_compared!(pair)
          sized_for_screens_of(pair)
          @readings.refuse_unreadable_on!(pair)
          @step_count&.refuse_unreadable_on!(pair)
          pair.zip(%w[first second], @lead_ins).each_with_index.map do |(cartridge, which, lead_in), side|
            Start.new(which: which, cartridge: cartridge, save: save_fitted_to(cartridge, which, @saves[side]), lead_in: lead_in,
                      count_passes: @step_count&.game_loop_count?(side) || false)
          end
        end
      end

      # THE SCREEN THE TWO ARE COMPARED ON, the size their console draws: any console's, so a
      # cartridge of the original is compared with ours whatever it was made for. Two cartridges
      # whose screens differ in size cannot be compared a pixel at a time, and are refused.
      private def sized_for_screens_of(pair)
        sizes = pair.map { |cartridge| Console.described(cartridge.console).screen_size }
        if sizes.uniq.size > 1
          raise ArgumentError, "The two cartridges show screens of different sizes: #{sizes.map { it.join(' by ') }.join(' and ')} " \
                               "pixels. A comparison can compare only two screens of one size. Compare two cartridges " \
                               "for one console."
        end

        @likeness = @likeness.sized_for(sizes.first)
        @compared = Compared.new(@comparing, @likeness, @readings)
      end

      # The screen each running console draws, which the emulator says, against the size the
      # comparison was laid out for: a cartridge that draws another size (a mode with more lines,
      # say) would be compared a row out of line, so it is refused.
      private def refuse_screens_not_described!(consoles)
        drawn = consoles.map { |console| [console.screen_width, console.screen_height] }
        return if drawn.all?(@likeness.screen_size)

        raise ArgumentError, "A cartridge draws a screen of #{drawn.map { it.join(' by ') }.uniq.join(' and ')} pixels. " \
                             "The comparison is for #{@likeness.screen_size.join(' by ')}. These cartridges cannot be compared."
      end

      # The screen's size as soon as it can be known without opening a cartridge: a built cartridge
      # says its console, and with none given the size is the Advance's, so a setting that cannot
      # be right is refused at once. A cartridge given by its path is looked at with the other.
      private def early_screen_size(first)
        return Console.described(first.console).screen_size if first.respond_to?(:console) && first.console
        return Likeness::ADVANCE_SCREEN if first.nil?

        nil
      end

      # A copy of +save+, the one this cartridge starts from, made to fit +cartridge+, or nil
      # for none.
      private def save_fitted_to(cartridge, which, save)
        save && Playthrough.save_fitted_to(cartridge, save.dup)
      rescue ArgumentError => e
        raise ArgumentError, "The #{which} cartridge of the comparison cannot start from #{@one_save ? 'the' : 'its'} save. " \
                             "#{e.message}"
      end

      # The save each cartridge starts from, the first's and then the second's: one save both
      # hold (`save:`), or one for each (`saves:`). Each is read as `save:` is for one cartridge.
      private def saves_for_each(save, saves)
        unless save.nil? || saves.nil?
          raise ArgumentError, "A comparison was given `save:` and `saves:`. Give `save:` or `saves:`: `save:` is one save " \
                               "both cartridges start from, and `saves:` is a save for each."
        end
        @one_save = !save.nil?
        return [Playthrough.save_from(save)] * 2 if saves.nil?

        refuse_malformed_saves!(saves)
        %w[first second].zip(saves).map do |which, given|
          Playthrough.save_from(given)
        rescue ArgumentError => e
          raise ArgumentError, "The save for the #{which} cartridge in `saves:` is wrong. #{e.message}"
        end
      end

      private def refuse_malformed_saves!(given)
        return if given.is_a?(Array) && given.size == 2

        raise ArgumentError, "`saves:` was #{given.inspect}. It must be a list of two, one for each cartridge. Each is a " \
                             "save, the path of a save file, or nil for none. Write it like `saves: [our_save, nil]`."
      end

      # What a report says of the saves the two started from.
      private def save_sentences
        return ["Both cartridges started from the same save."] if @one_save
        return [] if @saves.none?
        return ["Each cartridge started from a save of its own."] if @saves.all?

        ["The #{@saves.first ? 'first' : 'second'} cartridge started from a save, and the other from power-on."]
      end

      # Play both on +tape+ and compare them, and say what was found.
      def run(tape)
        ignored = @ignored.frame_ranges_on(tape)
        consoles = starts.map(&:console)
        refuse_screens_not_described!(consoles)
        show_layers_asked_for(consoles)
        reporter = ->(drift, pictures, part) { drift_with_report(drift, pictures, part, tape) } if @reports_in
        lined_up = @step_count&.lined_up_on(*consoles, @likeness.looked_at.fixed_part)
        lined_up&.skip_passes_under_way! if @lead_ins.any?
        pair = SideBySide.new(*consoles, @compared, ignored, looked_at: @likeness.looked_at.on_tape(tape),
                                                             torn: TornFrames.for(@torn_side, @likeness),
                                                             carrying_on: @carrying_on, reporter: reporter, lined_up: lined_up)
        # A pair that has stopped plays no more frames, and is still told a moment that
        # names the very frame it stopped on: that one it reached. +due+ is the frame the
        # tape is on after each step, so a step is past where the pair stopped when it is
        # due later than the pair has played — a moment after a hold that was cut short
        # included.
        due = 0
        tape.steps.each do |step|
          due += step.frames
          break if pair.stopped? && due > pair.frames

          step.play(pair)
        end
        pair.end_playing
        Result.new(frames: pair.frames, moments: pair.moments, drifts: pair.drifts)
      rescue ReportNotWritten => e
        raise e.after(pair.drifts)
      end

      # Leave out of each console's picture what `layers:` leaves out, for the rest of the
      # playing. A console whose emulator draws every layer together cannot, and is refused
      # saying which cartridge it was.
      private def show_layers_asked_for(consoles)
        return unless @shown_layers

        consoles.zip(%w[first second], cartridges, @shown_layers).each do |console, which, cartridge, shown|
          next unless shown

          console.showing(**shown)
          console.leave_out_backdrop! if sprites_alone?(console, shown)
        rescue ArgumentError => e
          raise ArgumentError, "`layers:` was #{@layers.inspect}, and the #{which} cartridge is for a " \
                               "#{Console.for(cartridge.console).title}. #{e.message} Remove `layers:`, or leave the " \
                               "sprites out with `ignoring_rectangles:`."
        end
      end

      # THE SETTINGS OF A COMPARISON THAT A PICTURE OF ONE FRAME HAS A USE FOR, each meaning
      # what it means of a comparison: the parts of the screen that are not looked at,
      # which are never marked, and where the two cartridges start.
      PICTURE_SETTINGS = %i[ignoring_rectangles looking_at pixels_apart save saves lead_ins].freeze

      # The comparison that plays the two for a picture of one frame (see PictureRequest),
      # which takes those settings and no others. A part of the screen said for a stretch of
      # frames or by a block is refused there: one frame is marked by one fixed part.
      def self.for_picture(first, second, moments, **settings)
        unknown = settings.keys - PICTURE_SETTINGS
        if unknown.empty?
          return new(first, second, moments, **settings).tap(&:refuse_moving_part_in_picture!)
        end

        known = [:at, :difference, *PICTURE_SETTINGS].map { |name| "`#{name}:`" }.join(", ")
        raise ArgumentError, "A side-by-side picture has no setting named #{unknown.map(&:inspect).join(' or ')}. " \
                             "Its settings are #{known}."
      end

      # Play each cartridge on +tape+ as far as the frame +request+ asks for, a
      # PictureRequest, and write the picture: their two screens on that frame and where
      # the two differ. Nothing is compared on the way there. The path of the file is
      # handed back.
      def write_picture_of_tape(tape, request)
        to_the_frame = tape.up_to(request.frame_on(tape))
        request.write(screen_pair(starts.map { |start| start.played_by(start.tape_said(to_the_frame)).game.frame_gba }))
      end

      # The same of +playthrough+'s script, played on the first cartridge alone to learn its
      # presses. A moment the script does not name is refused before that; a frame past
      # its end cannot be, since how long a script plays is not known until it has.
      def write_picture_of_playthrough(playthrough, request)
        request.refuse_moment_not_among!(@moments)
        write_picture_of_tape(starts.first.played_by(playthrough).tape, request)
      end

      def refuse_moving_part_in_picture!
        return unless @likeness.looked_at.changes_with_frame?

        raise ArgumentError, "A side-by-side picture is of one frame, so it takes the parts of the screen as a list of " \
                             "rectangles. Give `ignoring_rectangles:` and `looking_at:` as lists, like " \
                             "`ignoring_rectangles: [[0, 128, 240, 32]]`."
      end

      # Two screens that were kept, with where they differ of the places that are looked at:
      # +part+, or the part looked at on every frame where none is said.
      private def screen_pair(pictures, part = @likeness.looked_at.fixed_part)
        ScreenPair.new(*pictures, @likeness.differing_places(*pictures, part), @likeness.screen_size.first)
      end

      # Play +playthrough+'s script on each cartridge by itself, compare the two at each
      # named moment, and say what was found.
      def run_script(playthrough)
        at_moments = AtMoments.new(sides_played_by(playthrough), compared: @compared, frames_apart: @frames_apart,
                                                                 left_out: @ignored.moments_left_out(@moments),
                                                                 part: @likeness.looked_at.fixed_part)
        drifts = []
        at_moments.each_drift do |drift, pictures, reached|
          drifts << (@reports_in ? drift_with_moment_report(drift, pictures, reached, at_moments.sentences) : drift)
          break unless @carrying_on
        end
        Result.new(frames: at_moments.first_frames, moments: at_moments.moments, drifts: drifts)
      rescue ReportNotWritten => e
        raise e.after(drifts)
      end

      # Each cartridge played by the script on its own, the first and then the second.
      # Every reading is read at each moment as the cartridge reaches it, since by the end
      # of the playing it has moved on.
      private def sides_played_by(playthrough)
        starts.each_with_index.map do |start, side|
          readings = {}
          played = start.played_by(playthrough) { |moment, game| readings[moment] = @readings.values_from(game, side) }
          AtMoments::Side.new(played: played, readings: readings)
        end
      end

      # A drift with its report written, and the folder it went into noted on it.
      # +pictures+ is the two screens on the frame it began and +part+ the part of the screen
      # looked at there. The tape is handed over once for each cartridge, said to start the
      # way that cartridge was started.
      private def drift_with_report(drift, pictures, part, tape)
        report = DriftReport.new(drift, screen_pair(pictures, part), tapes: starts.map { |start| start.tape_said(tape) },
                                                               **what_any_report_has(@compared.sentences + @ignored.sentences(tape)))
        drift.with(report: report.write_in(@reports_in))
      end

      # The same of a drift at a moment. +reached+ is how each cartridge got there, and
      # +at_moments+ the sentences that say how the two were compared.
      private def drift_with_moment_report(drift, pictures, reached, at_moments)
        report = MomentReport.new(drift, screen_pair(pictures), reached: reached,
                                                                **what_any_report_has(@compared.sentences("A moment") + at_moments))
        drift.with(report: report.write_in(@reports_in))
      end

      private def what_any_report_has(settings) = { cartridges: cartridges, settings: settings + starting_sentences }

      # A comparison lines two screens up, and frames rectangles on them, at the size the console's
      # description says. A console whose cartridge the reader cannot play, or whose screen changes
      # size as its program runs, is refused rather than compared wrong
      # (Console::Kit#compared_side_by_side?).
      private def refuse_cartridges_not_compared!(pair)
        which, cartridge = %w[first second].zip(pair).find do |_, each|
          !Console.for(each.console).compared_side_by_side?
        end
        return unless which

        compared = Console.kits.select(&:compared_side_by_side?).map(&:title).join(" and ")
        raise ArgumentError, "The #{which} cartridge is for a #{Console.for(cartridge.console).title}. A comparison " \
                             "compares #{compared} cartridges only. To play that cartridge, use `play`."
      end

      private def refuse_malformed_lead_ins!(given)
        return if given.nil?
        return if given.is_a?(Array) && given.size == 2 && given.all? { |lead_in| lead_in.nil? || lead_in.is_a?(Playthrough) }

        raise ArgumentError, "`lead_ins:` was #{given.inspect}. It must be a list of two, one for each cartridge. Each is a " \
                             "playthrough to play on that cartridge first, or nil for none. " \
                             "Write it like `lead_ins: [nil, past_the_logos]`."
      end

      # Every setting a comparison has: the ones that say how alike, and the ones of its own.
      def self.settings
        [*how_alike_settings, :ignoring_frames, :layers, :forgiving_torn_frames_of, :readings, :comparing, :carrying_on, :same,
         :frames_apart, :save, :saves, :lead_ins, :reports_in, :by_passes, :pass_count_wraps_at, :reads_buttons_every_frame,
         :skipping_still_frames_of]
      end

      # Passes and still frames are two counts of steps (see LinedUp), and a comparison lines the
      # two cartridges up by one of them at most.
      private def refuse_two_step_counts!(passes, still_frames)
        return unless passes && still_frames

        raise ArgumentError, "The comparison was given `by_passes:` and `skipping_still_frames_of:`. A comparison can line " \
                             "the two cartridges up by their passes or by the frames whose picture changed, not by both. " \
                             "Remove one of them."
      end

      # What a comparison lined up step by step cannot do yet, or at all. On the same script
      # there is no tape to line up. The strict rule for torn frames needs the frame after each
      # one, and a report's tape would play the second cartridge on the first one's frames,
      # which is not how it was played.
      private def refuse_settings_wrong_for_lined_up!(same:, torn:, reports_in:)
        return unless @step_count

        said = []
        said << "`same: :script`" if same == :script
        said << "`forgiving_torn_frames_of:`" if torn
        said << "`reports_in:`" if reports_in
        return if said.empty?

        setting = @step_count.setting_name
        raise ArgumentError, "The comparison is lined up step by step, with #{setting}. It was given #{said.join(' and ')}. " \
                             "A comparison lined up step by step cannot use #{said.size == 1 ? 'that setting' : 'those settings'}. " \
                             "Remove #{said.size == 1 ? 'it' : 'them'}, or remove #{setting} to compare frame by frame."
      end

      # The settings that say how alike two pictures have to be and which of them is looked at.
      def self.how_alike_settings = [*Likeness::SETTINGS, *LookedAt::SETTINGS]

      # What the two ways of feeding the second cartridge each make no sense with. On the
      # same script there is no frame the two share, so nothing can be said in frames in a
      # row or in frame numbers; and with no moment named there is nowhere to compare. On
      # the same tape the two are always on the same frame, so they cannot be frames apart.
      private def refuse_settings_wrong_for_same!(how_alike)
        unless %i[tape script].include?(@same)
          raise ArgumentError, "`same:` was #{@same.inspect}. It must be `:tape` or `:script`. `:tape` gives both cartridges " \
                               "the same presses on the same frames. `:script` plays the script on each cartridge by itself."
        end
        return refuse_frames_apart_on_tape! unless same_script?

        refuse_invalid_frames_apart!
        refuse_script_with_no_moment!
        refuse_frame_counts_on_script!(how_alike)
        refuse_per_frame_settings_on_script!
        refuse_every_moment_left_out!
        refuse_moments_sharing_one_folder! if @reports_in
      end

      # What only a comparison frame by frame can do: a part of the screen that changes with
      # the frame, the strict rule for torn frames, which needs the frames either side, and
      # the picture without some of its layers, which is set on the two consoles it plays.
      private def refuse_per_frame_settings_on_script!
        said = []
        said << "a part of the screen for a stretch of frames or from a block" if @likeness.looked_at.changes_with_frame?
        said << "`forgiving_torn_frames_of:`" if @torn_side
        said << "`layers:`" if @layers
        return if said.empty?

        raise ArgumentError, "The comparison is on the same script. It was given #{said.join('; ')}. On the same script, " \
                             "the comparison looks at each named moment, not at each frame. Remove " \
                             "#{said.size == 1 ? 'that setting' : 'those settings'}, or compare on the same tape."
      end

      # Whether +console+ is told to show no background, so all its picture is the sprites and the
      # backdrop behind them. The backdrop is then taken out (Verifier#leave_out_backdrop!): it is
      # a colour each cartridge keeps its own way, and what is compared is what the sprites draw.
      private def sprites_alone?(console, shown)
        kept = shown[:only] ? Array(shown[:only]) : console.layers - Array(shown[:without])
        (kept - [:sprites]).empty?
      end

      # What each console is told to show, the first's and then the second's, as the reader's
      # `showing` takes it, nil for all of it; nil for both when `layers:` was not given.
      private def shown_layers_for_each(given)
        return nil if given.nil?
        return [LAYERS.fetch(given)] * 2 if LAYERS.key?(given)

        unless given.is_a?(Array) && given.size == 2 && !given.all?(Symbol)
          raise ArgumentError, "`layers:` was #{given.inspect}. It must be `:backgrounds`, for the picture without its " \
                               "sprites, or `:sprites`, for the sprites alone; or a list of two, one for each cartridge, " \
                               "like `layers: [%i[bg0 bg1], %i[bg1 bg2]]`."
        end

        %w[first second].zip(given).map { |which, one| shown_layers(one, which) }
      end

      private def shown_layers(one, which)
        return nil if one.nil?
        return LAYERS.fetch(one) if LAYERS.key?(one)
        return { only: one } if one.is_a?(Array) && one.all?(Symbol)
        return one if one.is_a?(Hash) && one.size == 1 && %i[only without].include?(one.keys.first)

        raise ArgumentError, "`layers:` for the #{which} cartridge was #{one.inspect}. It must be a list of the layers " \
                             "to keep, like `%i[bg0 bg1]`, `{ only: [...] }` or `{ without: [...] }`, `:backgrounds`, " \
                             "`:sprites`, or nil for all of the picture."
      end

      # Leaving out every moment leaves nowhere to compare, the same as naming none, and
      # would find no drift whatever the two cartridges did.
      private def refuse_every_moment_left_out!
        return unless (@moments - @ignored.moments_left_out(@moments)).empty?

        raise ArgumentError, "`ignoring_frames:` leaves out every moment the script names, and the comparison is on the same " \
                             "script. The two cartridges are compared at each named moment, so there is nowhere left to " \
                             "compare them. Leave out fewer moments."
      end

      # A drift at a moment is reported in a folder named for the moment, and many disks do
      # not tell a capital letter from a small one: there, two moments that differ only in
      # their capitals are one folder, and the second report would be written over the first.
      private def refuse_moments_sharing_one_folder!
        first, second = @moments.group_by { |name| name.to_s.downcase }.values.find { |alike| alike.size > 1 }
        return unless first

        raise ArgumentError, "The moments #{first.inspect} and #{second.inspect} differ only in their capital letters. " \
                             "Their reports would be the same folder on a disk that does not tell capital letters from " \
                             "small letters. To write reports, give one of the two moments a different name."
      end

      private def refuse_frames_apart_on_tape!
        return if @frames_apart.nil?

        raise ArgumentError, "`frames_apart:` was given, and the comparison is on the same tape. On the same tape the two " \
                             "cartridges are always on the same frame. To use `frames_apart:`, give `same: :script` too."
      end

      private def refuse_invalid_frames_apart!
        return if @frames_apart.nil? || (@frames_apart.is_a?(Integer) && !@frames_apart.negative?)

        raise ArgumentError, "`frames_apart:` was #{@frames_apart.inspect}. It must be a whole number, 0 or more. It is how " \
                             "many frames apart the two cartridges can reach a moment."
      end

      private def refuse_script_with_no_moment!
        return if @moments.any?

        raise ArgumentError, "The comparison is on the same script, and the script names no moment. On the same script the two " \
                             "cartridges are compared at each named moment, so there is nowhere to compare them. " \
                             "Name a moment in the script, like `moment :at_the_door`."
      end

      private def refuse_frame_counts_on_script!(how_alike)
        if how_alike.key?(:frames_in_a_row)
          raise ArgumentError, "`frames_in_a_row:` was given, and the comparison is on the same script. On the same script the " \
                               "two cartridges are compared at each named moment and not on each frame. Remove `frames_in_a_row:`."
        end
        return unless @ignored.frame_numbers?

        raise ArgumentError, "`ignoring_frames:` holds a range of frame numbers, and the comparison is on the same script. " \
                             "Each cartridge counts its own frames there, so a frame number means a different place on each. " \
                             "Give a range of moments, like `ignoring_frames: [:title..:in_the_world]`."
      end

      private def refuse_non_boolean_carrying_on!(given)
        return if [true, false].include?(given)

        raise ArgumentError, "`carrying_on:` was #{given.inspect}. It must be true or false. Give `carrying_on: true` to " \
                             "play on past the first drift and list each one."
      end

      private def refuse_unknown_settings!(given)
        unknown = given - Comparison.how_alike_settings
        return if unknown.empty?

        raise ArgumentError, "A comparison has no setting named #{unknown.map(&:inspect).join(' or ')}. " \
                             "Its settings are #{Comparison.settings.map { |name| "`#{name}:`" }.join(', ')}."
      end

      # TWO RUNNING CARTRIDGES PLAYED AS ONE. The lines of a tape play themselves on this as
      # they do on a single playing: a hold goes to both with the same buttons down, a frame
      # at a time, and the two are compared after each. Unless it is carrying on, it stops
      # playing on the frame that makes a drift of it, part way through a hold if that is
      # where it falls.
      #
      # EACH THING THAT IS COMPARED COUNTS ITS OWN FRAMES IN A ROW — the picture, and each
      # reading. Asking for several frames in a row is asking that one frame of flicker is
      # not called drift, and a picture that flickers for one frame followed by a count
      # that is out for the next is two flickers and no drift. Counted together they would
      # be two frames in a row.
      #
      # CARRYING ON. Unless it is told to carry on, the pair stops at its first drift. Told
      # to, it plays on, and that drift is under way for as long as something goes on
      # differing that has differed for long enough: the frame on which nothing has is the
      # frame the two are back within the settings, and the drift's last frame is the one
      # before it.
      #
      # NO FRAME IS IN TWO DRIFTS. A thing that began to differ while a drift was under
      # way, or on the very frame after it, and goes on long enough to count, is the same
      # drift going on and not a second one that began inside the first. That cannot be
      # known on the frame the first thing stops, so a drift is not ended there: its last
      # frame is noted, and it is ended once nothing that could still join it is differing.
      #
      # A FRAME IS SEEN, THEN DECIDED. Each frame is looked at as soon as it is played, and
      # what can only be asked then is kept (an Observation). With the strict rule for torn
      # frames (TornFrames) a frame is decided a frame later, once the frame after it says
      # whether it was torn, and a run of torn frames once it settles; without, at once.
      class SideBySide
        attr_reader :frames

        # Every drift that has ended, in the order they happened.
        attr_reader :drifts

        # The frame each moment that has been reached was named on, as a pair: both
        # cartridges are on the same frame here, and a result says it for each.
        attr_reader :moments

        # ONE FRAME AS IT WAS SEEN: its number, the moment named before it, what was seen
        # (Compared::Seen, or nil on a frame that is not looked at), and what is kept from it
        # in case something begins to differ on it (Kept, or nil when nothing did). +step+ counts
        # the observations from 1, which is what frames in a row are counted in: one a frame, or
        # one a step when the two are lined up step by step. There +second_frame+ is the frame
        # the second cartridge showed the step on, and +pass+ the step where steps are passes;
        # both are nil otherwise.
        Observation = Data.define(:frame, :moment, :seen, :kept, :step, :pass, :second_frame)

        # WHAT IS KEPT FROM A FRAME ON WHICH SOMETHING DIFFERS, because by the time it has
        # differed long enough to be called drift both consoles have played on and the frame
        # cannot be asked for again: the two screens (for a report), how the pictures
        # differed, which video memories differed, and the part of the screen looked at.
        Kept = Data.define(:pictures, :picture_difference, :video_differences, :part)

        # THE FRAME A THING BEGAN TO DIFFER ON, and what was kept from it.
        Beginning = Data.define(:frame, :moment, :readings, :kept, :step, :pass, :second_frame)

        # A drift that has not ended, with what was kept from the frame it began.
        UnderWay = Struct.new(:drift, :kept)

        # Where a drift under way seems to have ended, and how: the frame looked at before the
        # one on which nothing had differed for long enough, and the step of that one.
        Lull = Data.define(:last_frame, :ended, :step)
        private_constant :Observation, :Kept, :Beginning, :UnderWay, :Lull

        # +compared+ is what is compared on each frame, +ignored+ the stretches that are not
        # looked at, as ranges of frame numbers, and +looked_at+ the part of the screen looked
        # at on each frame (LookedAt::OnTape). +torn+ is the strict rule for torn frames, or
        # nil. +reporter+ is handed each drift as it ends, with the two screens on the frame
        # it began and the part looked at there, and hands the drift back with its report
        # noted — or is nil, and then no screen is copied out, which is only worth doing for
        # a report. +lined_up+ is the two lined up step by step (LinedUp), or nil to compare
        # them frame by frame.
        def initialize(first, second, compared, ignored, looked_at:, torn:, carrying_on:, reporter:, lined_up: nil)
          @lined_up = lined_up
          @steps = 0
          @decided_frame = 0
          @first = first
          @second = second
          @compared = compared
          @ignored = ignored
          @looked_at = looked_at
          @torn = torn
          @carrying_on = carrying_on
          @reporter = reporter
          @frames = 0
          @moment = nil
          @began = {}
          @under_way = nil
          @lull = nil
          @drifts = []
          @moments = {}
        end

        def hold(buttons, frames)
          keys = Playthrough.key_mask(buttons)
          frames.times do
            @first.step(1, keys: keys)
            @second.step(1, keys: keys) unless @lined_up
            @frames += 1
            seen = @lined_up ? observe_step(keys) : observe
            next unless seen

            (@torn ? @torn.decide_waiting(seen, [@first, @second]) : [seen]).each do |decided|
              extend_or_end_differing_stretches(decided)
              return if stopped?
            end
          end
        end

        def mark(name)
          @moment = name
          @moments[name] = [@frames, @lined_up ? @lined_up.second_frames : @frames]
        end

        # Whether the pair plays no further: it has its first drift, and was not told to
        # carry on.
        def stopped? = !@carrying_on && @drifts.any?

        # The tape has run out: decide the last frame, if one is waiting, and end the drift
        # that is under way, if one is. It ended where it had seemed to, or it was still going
        # and ran to the last frame that was played.
        def end_playing
          @lined_up&.refuse_nothing_compared!
          (@torn&.waiting_observations || []).each do |waiting|
            break if stopped?

            extend_or_end_differing_stretches(waiting)
          end
          return end_drift_under_way(@lull.last_frame, @lull.ended) if @lull

          end_drift_under_way(@decided_frame, :tape_ran_out)
        end

        # The frame just played, looked at. The part of the screen is asked for on every frame
        # the two are on together, one `ignoring_frames:` leaves out included, so a block that
        # chooses it is asked in order and what it keeps from the frame before is never stale.
        # +step+ is the step the two are lined up on, or nil frame by frame; +passed_over+ says
        # the second went past it without showing it.
        private def observe(step: nil, passed_over: false)
          @steps += 1
          unseen = Observation.new(frame: @frames, moment: @moment, seen: nil, kept: nil, step: @steps,
                                   pass: (step if @lined_up&.passes?), second_frame: (@lined_up.second_frames if step))
          return unseen if passed_over

          part = @looked_at.part_on(@frames, @first, @second)
          return unseen if ignored_frame?

          seen = @compared.seen_on(@first, @second, part)
          unseen.with(seen: seen, kept: (kept_from(seen, part) if beginning?(seen)))
        end

        # The frame just played on the first cartridge, looked at if it is the frame the first
        # took a step on, with the second played on to the same step and held +keys+ as it goes.
        # Nil for a frame that took no step. A step the second goes past without showing is not
        # looked at.
        private def observe_step(keys)
          step = @lined_up.read_step_begun_on_first!(keys) or return nil

          observe(step: step, passed_over: !@lined_up.play_second_to_step!(step))
        end

        # Whether something may begin to differ on this frame. With the strict rule for torn
        # frames the frames before this one are not decided yet, so anything differing may be.
        private def beginning?(seen) = @torn ? seen.differed.any? : (seen.differed - @began.keys).any?

        private def kept_from(seen, part)
          picture = seen.differed.include?(PICTURE)
          Kept.new(pictures: ([@first.frame_gba, @second.frame_gba] if @reporter),
                   picture_difference: (@compared.picture_difference(@first, @second, part) if picture),
                   video_differences: (picture ? VideoDifference.between(@first, @second) : []), part: part)
        end

        # A thing that differs is remembered from the frame it began to, and is drift once
        # it has differed on every frame since for long enough. A frame on which it is
        # alike again ends its stretch, and so does a frame that is not looked at: nothing
        # is known about that one, so the frames either side of it are not in a row.
        private def extend_or_end_differing_stretches(observation)
          differed = observation.seen ? observation.seen.differed : []
          @began.keep_if { |thing, _beginning| differed.include?(thing) }
          start_differing_stretches(differed - @began.keys, observation)
          lasted = @began.select { |_thing, beginning| @compared.drift_after?(observation.step - beginning.step + 1) }
          if !@under_way
            start_drift_of(lasted)
          elsif lasted.empty?
            end_drift_once_settled(observation)
          else
            carry_drift_on(lasted.keys)
          end
          @decided_frame = observation.frame
        end

        # The drift goes on, and whatever has now differed for long enough is part of it —
        # which is also how a drift that had seemed to end turns out not to have.
        private def carry_drift_on(things)
          @lull = nil
          @under_way.drift = @under_way.drift.with(differed: @under_way.drift.differed | things)
        end

        # Nothing has differed for long enough on this frame, so the drift seems to have
        # ended on the frame before. It is ended for good once nothing is still differing
        # that began before this frame was over: such a thing may yet count, and then it
        # was one drift all along.
        private def end_drift_once_settled(observation)
          @lull ||= Lull.new(last_frame: @decided_frame, ended: observation.seen ? :back_in_step : :not_looked_at,
                             step: observation.step)
          return if @began.any? { |_thing, beginning| beginning.step <= @lull.step }

          end_drift_under_way(@lull.last_frame, @lull.ended)
        end

        # Things that begin to differ on one frame share what is kept from it.
        private def start_differing_stretches(things, observation)
          return if things.empty?

          beginning = Beginning.new(frame: observation.frame, moment: observation.moment, readings: observation.seen.readings,
                                    kept: observation.kept, step: observation.step, pass: observation.pass,
                                    second_frame: observation.second_frame)
          things.each { |thing| @began[thing] = beginning }
        end

        # +lasted+ is the things that have now differed for long enough, each with the frame
        # it began on. With no drift under way they all began on the same frame: one that
        # began sooner would have been the drift a frame ago.
        private def start_drift_of(lasted)
          beginning = lasted.values.first or return

          kept = beginning.kept
          picture_differed = lasted.key?(PICTURE)
          drift = Drift.new(frame: beginning.frame, moment: beginning.moment, differed: lasted.keys, readings: beginning.readings,
                            pass: beginning.pass, second_frame: beginning.second_frame,
                            picture_difference: (kept.picture_difference if picture_differed),
                            video_differences: picture_differed ? kept.video_differences : [])
          @under_way = UnderWay.new(drift, kept)
          end_drift_under_way(nil, nil) unless @carrying_on
        end

        # +last_frame+ is the last frame of the drift and +ended+ how it ended — both nil
        # for a pair that stops at its first drift and so never finds out.
        private def end_drift_under_way(last_frame, ended)
          open = @under_way or return

          @under_way = nil
          @lull = nil
          drift = open.drift.with(last_frame: last_frame, ended: ended)
          @drifts << (@reporter ? @reporter.call(drift, open.kept.pictures, open.kept.part) : drift)
        end

        private def ignored_frame? = @ignored.any? { |stretch| stretch.cover?(@frames) }
      end
      private_constant :SideBySide
    end
  end
end
