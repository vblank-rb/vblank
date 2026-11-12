# frozen_string_literal: true

require "zlib"

module VBlank
  module Playthroughs
    # THE PRESSES OF A PLAYTHROUGH, WRITTEN DOWN: which buttons were down on each frame, and
    # the frame each named moment fell on.
    #
    # A script sets out what to do; a tape records what was done. The difference matters the moment
    # a script watches the game: "walk right until the door" is as many frames as THIS game
    # took to reach the door, and the tape holds that number. So a tape is the same presses
    # on the same frames whatever it is played on — which is what lets two cartridges be
    # given exactly the same game to play, and their pictures laid side by side.
    #
    #   tape = walk.play(cartridge).tape
    #   tape.write("walk.tape")
    #   Tape.read("walk.tape").play(another_cartridge) { |moment, game| ... }
    #
    # IT IS PLAIN TEXT, a line for each stretch of frames with the same buttons down, so a
    # person can read one and a change to one shows as a change to a few lines:
    #
    #   vblank tape 1
    #   recorded on: HERO 0x5C0FFEE5
    #   starts from: power-on
    #
    #   10 -
    #   1 down
    #   1 -
    #   20 right up
    #   moment walked
    #
    # Three lines of heading, always those three and in that order. Then a count and the
    # buttons down for that many frames, `-` for none; and a moment on a line of its own,
    # naming the frame the line before it ended on.
    #
    # WHAT IT WAS RECORDED ON IS FOR A PERSON. The cartridge's title and a checksum of its
    # bytes show which game and which build the tape came from. Nothing checks them against
    # the cartridge it is played on: playing a tape on a different cartridge is the point.
    #
    # WHERE IT STARTED IS HELD TO. The third line reads `power-on`, or `a save` for a
    # cartridge that held one when the console was switched on, and either can end
    # ` after a lead-in`. The same presses from anywhere else are a different game, so a
    # tape recorded from a save is played from one, and one recorded after a lead-in
    # after one.
    #
    # +steps+ are the lines in order — each a Hold or a Moment, the same steps a script is
    # made of, so a tape is played by the same playing a script is.
    #
    # A TAPE CAN COUNT PASSES OF THE GAME LOOP IN PLACE OF FRAMES (+in_passes+, and see
    # PassStepper), and then a line's count is passes and a moment names a pass. One extra
    # line of heading marks it, `counts: passes`, or `counts: variable steps` for a variable of the
    # game. Such a tape plays the same game at any speed on any way of running it, where a tape of
    # frames holds its presses to one cartridge's timing. A tape of frames does not have the line.
    Tape = Data.define(:title, :checksum, :starts_from, :steps, :in_passes)

    class Tape
      # What a tape's file opens with: what it is, and which way of writing one this is.
      FIRST_LINE = "vblank tape 1"

      # How a stretch of frames with no button down is written.
      NOTHING_DOWN = "-"

      # The line of heading a tape of passes has, and what it can hold.
      COUNTS = "counts: "
      COUNTS_PASSES = "passes"
      COUNTS_VARIABLE = "variable "

      # Where a playthrough starts, as the tape records it: the console switched on with a
      # cartridge nobody has played, or with one holding a save. A save is recorded with a
      # checksum of its bytes, like the cartridge's, for a person to tell which save the
      # tape goes with. The save itself is not in the tape: a tape is the presses, and
      # played on another cartridge it wants that one's own.
      #
      # And it records whether a lead-in was played first, with ` after a lead-in` on the
      # end of either. The lead-in's presses are not on the tape — a lead-in is how THIS
      # cartridge gets to where the playing begins, and another cartridge has its own —
      # so all the tape can record is that there was one.
      POWER_ON = "power-on"
      A_SAVE = /\Aa save 0x\h{8}\z/
      AFTER_A_LEAD_IN = " after a lead-in"

      # The tape of +steps+ played on +cartridge+. What it records as its cartridge is the
      # title in the cartridge's own header and a checksum of every byte of it. +save+ is
      # the save memory the cartridge held when the console was switched on, or nil, and
      # +led_in+ whether a lead-in was played before the first of the steps. +in_passes+ is
      # what the tape counts, nil for frames.
      def self.recorded_on(cartridge, steps, save:, led_in: false, in_passes: nil)
        title, checksum = title_and_checksum_of(cartridge)
        new(title: title, checksum: checksum, starts_from: start_said(save: save, led_in: led_in), steps: steps, in_passes: in_passes)
      end

      # Where a playing started, as a tape records it. +save+ is the save memory the
      # cartridge held as the console was switched on, or nil, and +led_in+ whether a
      # lead-in was played first.
      def self.start_said(save:, led_in:)
        from = save ? format("a save 0x%08X", Zlib.crc32(save.to_sav)) : POWER_ON
        "#{from}#{AFTER_A_LEAD_IN if led_in}"
      end

      # Whether +said+ is a way a tape can record where it started.
      def self.valid_start?(said)
        from = said.delete_suffix(AFTER_A_LEAD_IN)
        from == POWER_ON || A_SAVE.match?(from)
      end

      # The same presses, marked as started somewhere else: what a comparison writes
      # down for a cartridge it started its own way.
      def started_from(save:, led_in:) = with(starts_from: Tape.start_said(save: save, led_in: led_in))

      # What a person tells one cartridge from another by: the title in its own heading,
      # and a checksum of every byte of it, which shows which build of that game it is.
      # Each kind of cartridge keeps its title somewhere else in its header, so it is asked.
      # A game that was not built into a cartridge has no bytes, and gives a checksum of its own.
      def self.title_and_checksum_of(cartridge)
        checksum = cartridge.is_a?(UnbuiltGame) ? cartridge.checksum : Zlib.crc32(cartridge.buffer)
        [printable(cartridge.header_title), checksum]
      end

      # Those two as they are written for a person, on a tape and in a report: `HERO 0x5C0FFEE5`.
      def self.label(title, checksum) = "#{title} #{format('0x%08X', checksum)}"
      def self.label_of(cartridge) = label(*title_and_checksum_of(cartridge))

      # The cartridge this tape was recorded on, written the same way.
      def recorded_on_label = Tape.label(title, checksum)

      # A header's title as a line a person can read. The header holds twelve bytes, padded
      # with noughts, and a cartridge somebody else made can hold anything in them — so a
      # byte that is not a printable letter is written as `?`.
      def self.printable(header_title)
        header_title.b.delete("\0").gsub(/[^\x20-\x7E]/n, "?").strip.encode("UTF-8")
      end

      # The tape in the file at +path+.
      def self.read(path)
        raise ArgumentError, "There is no tape file at #{path}. Give the path of a file that `Tape#write` wrote." unless File.file?(path)

        parse(File.read(path), from: path)
      end

      # The tape +text+ is. +from+ names where the text came from, for an error to name.
      def self.parse(text, from: "This text") = Reader.new(text, from).read_tape

      # A tape holds nothing but names and numbers, and is made so that every core can read
      # it: it can be kept in a constant, and handed from one Ractor to another.
      def initialize(title:, checksum:, starts_from:, steps:, in_passes: nil)
        super(**Ractor.make_shareable({ title: title.dup, checksum: checksum, starts_from: starts_from.dup, steps: steps.dup,
                                        in_passes: in_passes }))
      end

      # Play the tape on +cartridge+, exactly as a playthrough plays its script: the block is
      # handed each moment's name and the running cartridge, and what comes back is the same.
      #
      # A tape recorded from a save is played from one, and one recorded after a lead-in
      # is played after one: from anywhere else it would be the same presses on a
      # different game.
      def play(cartridge, save: nil, lead_in: nil, pictures_in: nil, on: nil, window: nil,
               progress: Messages::Progress.silent, &at_each_moment)
        refuse_missing_save!(save)
        refuse_missing_lead_in!(lead_in)
        Playthrough::Playing.play(title, steps, cartridge, save: save, lead_in: lead_in, pictures_in: pictures_in, on: on,
                                                           window: window, in_passes: in_passes, progress: progress,
                                                           &at_each_moment)
      end

      # Play the tape on +first+ and on +second+ together, comparing the two pictures after
      # every frame. +settings+ set how alike they have to be, and which stretches of the
      # tape are not looked at (see Comparison).
      #
      # A tape recorded from a save is compared from one (`save:`), and one recorded after
      # a lead-in with a lead-in for each cartridge (`lead_ins:`).
      def compare(first, second, **settings)
        refuse_compare_of_passes!
        refuse_missing_save!(save_for_both(settings), "tape.compare(first, second, save: ...)")
        refuse_missing_lead_in!(Array(settings[:lead_ins]).compact.first, "tape.compare(first, second, lead_ins: [..., ...])")
        refuse_settings_of_scripts!(settings)
        Comparison.new(first, second, moments.keys, **settings).run(self)
      end

      # WRITE ONE PICTURE OF ONE FRAME ON TWO CARTRIDGES at +path+: the tape played on
      # +first+ and on +second+ as far as the frame +at+, and their two screens there side
      # by side with the difference between them (see Comparison::PictureRequest). +at+ is
      # the frame, by its number or by the name of a moment, and +difference+ whether the
      # picture marks where the two differ. +settings+ are the ones of a comparison that a
      # picture has a use for (see Comparison::PICTURE_SETTINGS). The path is handed back.
      #
      # A tape recorded from a save or after a lead-in is given them here, as it is for a
      # comparison.
      def write_side_by_side_picture(first, second, path, at: nil, difference: true, **settings)
        refuse_compare_of_passes!
        refuse_missing_save!(save_for_both(settings),
                             "tape.write_side_by_side_picture(first, second, path, at: ..., save: ...)")
        refuse_missing_lead_in!(Array(settings[:lead_ins]).compact.first,
                                "tape.write_side_by_side_picture(first, second, path, at: ..., lead_ins: [..., ...])")
        request = Comparison::PictureRequest.new(path, at: at, difference: difference)
        Comparison.for_picture(first, second, moments.keys, **settings).write_picture_of_tape(self, request)
      end

      # A comparison looks at two cartridges frame by frame, and two cartridges take different
      # frames over the same passes.
      private def refuse_compare_of_passes!
        return unless in_passes

        raise ArgumentError, "This tape counts passes, and a comparison plays two cartridges frame by frame. To compare " \
                             "two cartridges, use a tape of frames, or `same: :script` on the playthrough."
      end

      # THE SAME GAME AS A TAPE OF FRAMES, for +cartridge+ alone: a tape of passes played once on it,
      # with each line holding the frames its passes took there. A tape of frames comes back as it
      # is. What comes back is as strict as any tape of frames, and this tape stays the master.
      def in_frames_on(cartridge)
        return self unless in_passes

        cartridge = Playthrough.cartridge_from(cartridge)
        refuse_export_from_elsewhere!
        Playthrough.refuse_unusable_pass_count!(cartridge, in_passes)
        running = Playthrough.power_on(cartridge, count_passes: in_passes == true)
        stepper = PassStepper.new(running, in_passes)
        taping = Taping.new
        steps.each { |step| step.frames.zero? ? taping.moment(step.name) : hold_on(stepper, step, taping) }
        Tape.recorded_on(cartridge, taping.steps, save: nil)
      end

      private def hold_on(stepper, step, taping)
        before = stepper.frames_played
        stepper.step(step.frames, keys: Playthrough.key_mask(step.buttons))
        taping.hold(step.buttons, stepper.frames_played - before)
      end

      # WRITE THE TAPE AS A SCRIPT FOR mGBA at +path+ (see TapeExport), for +cartridge+. +pictures_in+
      # is a folder for mGBA to write the screen at each moment into, to lay beside the pictures
      # here. The path is handed back.
      def write_mgba_script(cartridge, path, pictures_in: nil)
        File.write(path, TapeExport.mgba_script(exported_on(cartridge), pictures_in: pictures_in))
        path
      end

      # WRITE THE TAPE AS A BIZHAWK MOVIE at +path+ (see TapeExport), for +cartridge+. The path is
      # handed back.
      def write_bizhawk_movie(cartridge, path)
        cartridge = Playthrough.cartridge_from(cartridge)
        File.binwrite(path, TapeExport.bizhawk_movie(exported_on(cartridge), cartridge))
        path
      end

      private def exported_on(cartridge)
        cartridge = Playthrough.cartridge_from(cartridge)
        refuse_export_from_elsewhere!
        unless cartridge.console == Console::ADVANCE.name
          raise ArgumentError, "A tape is written out for another emulator for a Game Boy Advance cartridge only, and this " \
                               "one is for #{cartridge.console}. To fix this, give a Game Boy Advance cartridge."
        end
        in_frames_on(cartridge)
      end

      private def refuse_export_from_elsewhere!
        return unless recorded_from_save? || recorded_after_lead_in?

        raise ArgumentError, "This tape starts from #{starts_from}. An export starts from power-on with empty save memory, " \
                             "so it would play another game. To fix this, record a tape from power-on."
      end

      # The settings that only mean something of a script played on each cartridge by
      # itself. They are refused here, as a tape's own mistake, before the comparison
      # reads the rest and says something about a script that is not there.
      private def refuse_settings_of_scripts!(settings)
        asked = if settings[:same] == :script
                  "`same: :script`"
                elsif settings.key?(:frames_apart)
                  "`frames_apart:`"
                end
        return unless asked

        raise ArgumentError, "#{asked} was given to a tape. A tape holds the presses that were made and no script, " \
                             "so it cannot play each cartridge by itself. Compare the playthrough's script: " \
                             "`walk.compare(first, second, same: :script)`."
      end

      def recorded_from_save? = !starts_from.start_with?(POWER_ON)
      def recorded_after_lead_in? = starts_from.end_with?(AFTER_A_LEAD_IN)

      # +how+ is how the call that was made is written with the save in it.
      # A comparison's save as far as a tape recorded from a save needs one: `save:`, or `saves:`
      # when it gives one to each cartridge, since each plays the tape from its own start.
      private def save_for_both(settings)
        saves = settings[:saves]
        return settings[:save] unless saves.is_a?(Array) && saves.size == 2

        saves if saves.all?
      end

      private def refuse_missing_save!(save, how = "tape.play(cartridge, save: ...)")
        return unless recorded_from_save? && save.nil?

        raise ArgumentError, "This tape was recorded on a cartridge that started from a save. From power-on, the same " \
                             "presses play a different game. Give the save to start from: `#{how}`."
      end

      private def refuse_missing_lead_in!(lead_in, how = "tape.play(cartridge, lead_in: ...)")
        return unless recorded_after_lead_in? && lead_in.nil?

        raise ArgumentError, "This tape was recorded after a lead-in, which is not on the tape. With no lead-in, the same " \
                             "presses start in a different place. Give the lead-in to play first: `#{how}`."
      end

      # THE TAPE AS FAR AS +frame+ AND NO FURTHER: the same presses, ending on that frame. It
      # is how a moment part way through is got back to — play this, and the cartridge is
      # on that frame. A hold the frame falls inside is cut short there. A moment is kept
      # when the frame it names was played, the last frame included. A frame past the end
      # of the tape is the whole tape.
      def up_to(frame)
        refuse_frame_below_one!(frame)
        with(steps: steps_up_to(frame))
      end

      private def refuse_frame_below_one!(frame)
        return if frame.is_a?(Integer) && frame >= 1

        raise ArgumentError, "A tape was asked for its frames up to #{frame.inspect}. Frames are counted from 1, " \
                             "so give a whole number, 1 or more."
      end

      # A moment after a hold that was cut short named a later frame than the cut, so
      # nothing after the cut is kept. One after a hold that ended on the frame names that
      # frame, and is.
      private def steps_up_to(frame)
        played = 0
        steps.each_with_object([]) do |step, kept|
          left = frame - played
          return kept if left.zero? && step.frames.positive?
          return kept << step.with(frames: left) if step.frames > left

          kept << step
          played += step.frames
        end
      end

      # A run of frames with the same buttons down: +frames+ is the range of them,
      # counted from 1, and +buttons+ what was down.
      Stretch = Data.define(:frames, :buttons)

      # WHAT WAS DOWN ON EACH OF THE FRAMES +frames+, a range of frame numbers: one
      # Stretch for each run of them with the same buttons down, in order. A moment
      # between two lines of the same buttons does not split a run, since a moment is
      # no frames long; and a run that reaches outside the range is cut to it.
      def presses_within(frames)
        ends_on = 0
        steps.each_with_object([]) do |step, runs|
          next if step.frames.zero?

          starts_on = ends_on + 1
          ends_on += step.frames
          inside = [starts_on, frames.begin].max..[ends_on, frames.end].min
          next if inside.none?

          longer = runs.last&.buttons == step.buttons
          longer ? runs[-1] = runs.last.with(frames: runs.last.frames.begin..inside.end) : runs << Stretch.new(frames: inside, buttons: step.buttons)
        end
      end

      # How many frames the tape plays.
      def frames = steps.sum(&:frames)

      # The frame each named moment falls on, counted from 1.
      def moments
        played = 0
        steps.each_with_object({}) do |step, found|
          played += step.frames
          step.names.each { |name| found[name] = played }
        end
      end

      # The tape as the text of a file.
      def to_s
        heading = [FIRST_LINE, "recorded on: #{recorded_on_label}", "starts from: #{starts_from}", *counts_line, ""]
        (heading + steps.map(&:tape_line)).join("\n") << "\n"
      end

      # What a tape of passes records that it counts, and nothing for a tape of frames.
      private def counts_line
        return [] unless in_passes

        ["#{COUNTS}#{in_passes == true ? COUNTS_PASSES : "#{COUNTS_VARIABLE}#{in_passes}"}"]
      end

      # Write the tape to +path+, which is handed back.
      def write(path)
        File.write(path, to_s)
        path
      end

      # A TAPE BEING MADE, a line at a time — by a playing as it plays, and by a file as it
      # is read. Frames with the same buttons down run on from the ones before, so a wait
      # that watched the game for ninety frames is one line of ninety and not ninety of one;
      # and the buttons of a line are in the console's own order, so the same presses are
      # the same tape however they were written.
      class Taping
        attr_reader :steps, :frames

        def initialize
          @steps = []
          @frames = 0
        end

        def hold(buttons, frames)
          held = Playthrough.in_console_order(buttons)
          longer = @steps.last&.extended_by(held, frames)
          longer ? @steps[-1] = longer : @steps << Playthrough::Hold.new(buttons: held, frames: frames)
          @frames += frames
        end

        def moment(name) = @steps << Playthrough::Moment.new(name: name)

        # Every moment named so far.
        def names = @steps.flat_map(&:names)

        # The buttons held on each frame so far, one key mask a frame.
        def keys_by_frame
          @steps.grep(Playthrough::Hold).flat_map { |hold| Array.new(hold.frames, Playthrough.key_mask(hold.buttons)) }
        end
      end

      # ONE READING OF A TAPE'S TEXT. A tape is written by a program and read back by one, but
      # it is also a file a person can open and change, so every line that cannot be read is
      # an error saying which line, what is on it, and what a line there has to look like.
      class Reader
        def initialize(text, from)
          @lines = text.lines.map(&:strip)
          @from = from
          @taping = Taping.new
        end

        def read_tape
          refuse_unknown_first_line!
          title, checksum = read_recorded_on
          starts_from = read_starts_from
          in_passes = read_counts
          @lines.each_with_index.drop(in_passes ? HEADING_LINES + 1 : HEADING_LINES).each { |line, at| read_step(line, at + 1) }
          Tape.new(title: title, checksum: checksum, starts_from: starts_from, steps: @taping.steps, in_passes: in_passes)
        end

        private

        HEADING_LINES = 3
        private_constant :HEADING_LINES

        def refuse_unknown_first_line!
          return if @lines.first == FIRST_LINE

          found = @lines.empty? ? "The file is empty." : "Line 1 is #{@lines.first.inspect}."
          raise ArgumentError, "#{@from} is not a tape. A tape starts with the line `#{FIRST_LINE}`. #{found}"
        end

        def read_recorded_on
          said = @lines[1].to_s.match(/\Arecorded on: (.*) 0x(\h{8})\z/) or
            raise_unreadable_line!(2, "Line 2 must say what the tape was recorded on, like `recorded on: HERO 0x5C0FFEE5`.")
          [said[1], said[2].to_i(16)]
        end

        def read_starts_from
          said = @lines[2].to_s.delete_prefix("starts from: ")
          return said if @lines[2] != said && Tape.valid_start?(said)

          raise_unreadable_line!(3, "Line 3 must say where the playthrough starts: `starts from: #{POWER_ON}`, " \
                                    "or `starts from: a save 0x5C0FFEE5` with the checksum of the save. " \
                                    "Either can end with `#{AFTER_A_LEAD_IN.strip}`.")
        end

        # What the optional fourth line names as what the tape counts, or nil for frames.
        def read_counts
          line = @lines[HEADING_LINES].to_s
          return unless line.start_with?(COUNTS)

          said = line.delete_prefix(COUNTS)
          return true if said == COUNTS_PASSES

          name = said.delete_prefix(COUNTS_VARIABLE)
          return name.to_sym if said != name && !name.empty?

          raise_unreadable_line!(HEADING_LINES + 1, "Line 4 must say what the tape counts: `#{COUNTS}#{COUNTS_PASSES}`, " \
                                                    "or `#{COUNTS}#{COUNTS_VARIABLE}steps` with the name of a variable.")
        end

        def read_step(line, number)
          return if line.empty? || line.start_with?("#")

          first, *rest = line.split
          return read_moment(rest.join(" "), number) if first == "moment"

          unless first.match?(/\A[1-9]\d*\z/)
            raise_unreadable_line!(number, "A line must start with how many frames it lasts, as a whole number, 1 or more.")
          end
          @taping.hold(buttons_named(rest, number), first.to_i)
        end

        def buttons_named(words, number)
          raise_unreadable_line!(number, "After the count, name the buttons that are down, or write `#{NOTHING_DOWN}` for none.") if words.empty?
          return [] if words == [NOTHING_DOWN]

          if words.include?(NOTHING_DOWN)
            raise_unreadable_line!(number, "`#{NOTHING_DOWN}` means no button is down. Write `#{NOTHING_DOWN}` alone, or name the buttons.")
          end
          names = words.map(&:to_sym)
          unknown = (names - Playthrough.pressable_buttons).first or return names

          raise_unreadable_line!(number, "#{unknown.to_s.inspect} names a button the console does not have. " \
                                         "The buttons are #{Playthrough.pressable_button_words(as_symbols: false)}.")
        end

        # The rules are Moment's own, shared with a script; the words are a tape's.
        def read_moment(name, number)
          problem = Playthrough::Moment.problem_with(name.to_sym, named: @taping.names, any_frames: @taping.frames.positive?)
          return @taping.moment(name.to_sym) unless problem

          raise_unreadable_line!(number, format(MOMENT_PROBLEMS.fetch(problem), name: name))
        end

        MOMENT_PROBLEMS = {
          not_a_plain_name: "A moment needs a name made of letters, digits and underscores, like `moment at_the_door`.",
          before_any_frame: "A moment names the frame the line before it ended on. No line of frames comes before " \
                            "this one. Put the moment after a line of frames.",
          named_already: "The tape already has a moment named %<name>s. A name must mean one frame. " \
                         "Give this moment a different name.",
        }.freeze
        private_constant :MOMENT_PROBLEMS

        def raise_unreadable_line!(number, advice)
          raise ArgumentError, "#{@from} cannot be read at line #{number}: #{@lines[number - 1].to_s.inspect}. #{advice}"
        end
      end
    end
  end
end
