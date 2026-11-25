# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Diagnostics
    # A film of a running cartridge, or of two side by side, as an MP4 a person can watch without
    # running anything: the same moment played on each, a frame at a time with the same buttons,
    # and every frame of the parts asked for put next to each other. What a test holds frame by
    # frame, shown. Two builds of one game, or a game beside the cartridge it is a copy of, are
    # the usual pair; one side alone is a film of one game.
    #
    #   VBlank::Diagnostics::Film.make("door.mp4",
    #     sides: { "ours" => -> { Verifier.new(ours, frames: 0) }, "reference" => -> { Verifier.new(theirs, frames: 0) } },
    #     parts: [1..90, 200..240],
    #     keys: ->(frame) { :left if frame < 60 })
    #
    # A side is opened by a callable, the side's label its key, and the callable answers a running
    # cartridge whose next frame is the film's first: a Verifier told to play no frames, one a
    # playthrough left standing at the moment worth filming, or a Playthroughs::Probe a game drove
    # there (closing it takes its save folder away too). Film asks two things of it, and any
    # object that answers them can be filmed (an emulator of a game's own, say):
    #
    #   step(1, keys: mask)   play one frame with these buttons down (IR::Buttons.mask, a bit each)
    #   screen_picture        the picture now on screen: its pixels (the console's 15-bit colours, a
    #                         row at a time from the top), width and height (a Film::Picture)
    #
    # A side that cannot answer `screen_picture` may answer `screenshot(path)` instead, writing the picture
    # to +path+ as a PNG, which ImageMagick reads back: a file a frame, so slower. Film closes a side
    # when its frames are taken, if it answers `close`. Where there are two sides or more, they are
    # opened in order and then played at the same time, each in a copy of this process (fork); a
    # side that must know when its copy starts answers `played_in_another_process`. Each frame is
    # put together as soon as every side has played it (Reel), so the film costs about as long as
    # its slowest side takes to play.
    #
    # PARTS are ranges of frames to show, counted from one. Every frame up to the last one shown
    # is played, shown or not, so a part late in a long run costs the frames before it. The last
    # frame of each part is held a little under a second, so the jump to the next part is seen,
    # and the film's last frame is held until the film is at least three seconds long.
    #
    # KEYS answers the buttons held on a frame: a button's name, a list of them, or nil.
    #
    # SOUND is off unless asked for, and a film without it is the same MP4 it always was. +sound:+
    # names the side heard ("ours"), or `:side_by_side` (two sides, one on each speaker) or `:in_turn`
    # (the film shown once for each side, one heard each time); FilmSound says how each side's sound
    # is kept in step with its frames. A heard side answers one more thing:
    #
    #   last_frame_samples    the samples of the frame played last, left and right by turns
    #
    # It needs ImageMagick, which draws the labels and the frame numbers' letters once, and ffmpeg,
    # which makes the MP4. Both are looked for before any frame is played.
    class Film
      # The picture a side shows (#picture on a side).
      Picture = Data.define(:pixels, :width, :height)

      # The console shows sixty frames a second, and the MP4 plays them so.
      FRAME_RATE = 60

      PART_END_HOLD_SECONDS = 0.8
      SHORTEST_FILM_SECONDS = 3

      # Each picture is shown at twice the console's size unless +scale:+ sets another: at its
      # own size a frame is a postage stamp on a computer's screen. The MP4's way of keeping colour
      # needs an even width and height, which every console's screen has, and so has any whole
      # number of times it.
      PICTURE_SCALE = 2

      # The strip above the pictures: how tall, its colour, and the size of its writing.
      LABEL_STRIP_HEIGHT = 28
      LABEL_STRIP_COLOR = "#202020"
      LABEL_POINT_SIZE = 18
      # Where a side's label is written: its left edge and the line its letters stand on, so
      # every label stands on the same line whatever letters it has. The frame's number is set in
      # from the strip's top right corner.
      LABEL_BASELINE = "+12+20"
      FRAME_NUMBER_MARGIN = "+12+4"

      # The labels are written in the first of these that the computer has, and in ImageMagick's
      # own letters where it has none: a Mac's, then the one most Linux machines carry.
      LABEL_FONT_PATHS = ["/System/Library/Fonts/Supplemental/Arial.ttf",
                          "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"].freeze

      # A program Film runs, by the name a person knows it by: the commands that are it (ImageMagick
      # 7 is `magick`; 6, which Linux machines still ship, is `convert`) and the package to install.
      Tool = Data.define(:name, :commands, :package)
      IMAGEMAGICK = Tool.new(name: "ImageMagick", commands: %w[magick convert].freeze, package: "imagemagick")
      FFMPEG = Tool.new(name: "ffmpeg", commands: %w[ffmpeg].freeze, package: "ffmpeg")

      # Raised before any frame is played, when ImageMagick or ffmpeg is not installed.
      class MissingTool < StandardError; end

      # Make the film and write it to +path+, which is handed back. +search_path+ is where the
      # programs are looked for, the folders of a PATH; left out, it is this process's.
      # +scale+ is how many times the console's size each picture is shown at. +sound+ is which side
      # is heard (FilmSound), none unless given.
      def self.make(path, sides:, parts:, keys: ->(_frame) {}, scale: PICTURE_SCALE, sound: nil,
                    search_path: ENV.fetch("PATH", ""))
        new(sides: sides, parts: parts, keys: keys, scale: scale, sound: sound, search_path: search_path).write(path)
      end

      def initialize(sides:, parts:, keys:, scale:, search_path:, sound: nil)
        refuse_bad_sides!(sides)
        refuse_bad_parts!(parts)
        refuse_bad_scale!(scale)
        @sides = sides.transform_keys(&:to_s)
        @parts = parts
        @keys = keys
        @scale = scale
        @sound = sound
        @heard = sound.nil? ? [] : FilmSound.heard_labels(sound, @sides.keys)
        @commands = find_commands!([IMAGEMAGICK, FFMPEG], search_path)
        # A 15-bit colour's bytes, each pixel +scale+ times across: eight bits a channel, each level
        # stretched to fill its byte by repeating its top bits into the bottom, as Graphics::PNG
        # writes it. Worked out once a colour, as a picture holds far fewer colours than pixels.
        @wide_channels = Hash.new { |known, colour| known[colour] = Graphics::PNG.eight_bit_channels(colour) * scale }
      end

      # Play every side, put the pictures together and write the MP4 to +path+, handed back.
      def write(path)
        shown = @parts.flat_map(&:to_a)
        holds = hold_lengths(shown)
        film_sound = FilmSound.new(@sound, parts: @parts, holds: holds) unless @heard.empty?
        FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
        Dir.mktmpdir("film-") do |dir|
          pictures = film_sound ? File.join(dir, "pictures.mp4") : path
          reel = Reel.new(commands: @commands, labels: @sides.keys, scale: @scale, holds: holds, out: pictures)
          sounds = play_sides(shown, dir, reel)
          reel.finish
          next unless film_sound

          @sides.each_key.with_index { |label, side| film_sound.keep(label, sounds[side]) if @heard.include?(label) }
          add_sound(pictures, film_sound, dir, path)
        ensure
          reel&.abandon
        end
        path
      end

      # The picture in the PPM file +ppm+ (binary, eight bits a channel), as a Shot.
      def self.shot_from_ppm(ppm)
        header = ppm.match(/\AP6\s+(\d+)\s+(\d+)\s+255\s/n) or raise ArgumentError, "ImageMagick did not write a picture."
        width = header[1].to_i
        height = header[2].to_i
        Shot.new(width: width, height: height, colours: nil, rgb: ppm.byteslice(header.end(0), width * height * 3))
      end

      private

      # The sides play at the same time, each in a process of its own (#play_sides_at_once), and each
      # frame is handed to +reel+ as soon as every side has its picture. Where Ruby cannot start a
      # process that way (fork), or there is one side, they play one after another in this one, each
      # opened as the one before it closes. Answers each side's sound by frame (#arrived), in the
      # sides' order. +dir+ is a folder for a side that answers only `screenshot`.
      def play_sides(shown, dir, reel)
        @next_shown = 0 # the place in +shown+ of the next frame for the reel
        @last_shown = shown.each_with_index.to_h # each frame's last place in +shown+ (parts can overlap)
        @waiting = Array.new(@sides.size) { {} } # each side's pictures the reel will still be handed, by frame
        @sounds = Array.new(@sides.size) { {} }
        @arrivals = Mutex.new
        if @sides.size > 1 && Process.respond_to?(:fork)
          play_sides_at_once(shown, dir, reel)
        else
          @sides.each_value.with_index do |opener, side|
            running = open_side(opener, side)
            play_side(running, shown, side, dir) do |frame, shot, samples|
              arrived(side, frame, widened(shot), samples, shown, reel)
            end
          ensure
            running.close if running.respond_to?(:close)
          end
        end
        @sounds
      end

      def heard?(side) = @heard.include?(@sides.keys[side])

      def open_side(opener, side)
        opener.call.tap { |running| refuse_side_without_sound!(running, side) if heard?(side) }
      end

      # Side number +side+ has +picture+ (Widened) of +frame+, and +samples+, its sound where heard.
      # The reel is handed frames in the order shown, each as soon as every side has it. Parts can
      # come in any order and overlap, and a side plays its frames in the game's order, each once,
      # so a picture is kept until the last place it is shown has been handed over.
      def arrived(side, frame, picture, samples, shown, reel)
        @arrivals.synchronize do
          @sounds[side][frame] = samples if heard?(side)
          @waiting[side][frame] = picture
          while @next_shown < shown.size && @waiting.all? { |pictures| pictures.key?(shown[@next_shown]) }
            next_frame = shown[@next_shown]
            reel.add(next_frame, @waiting.map { |pictures| pictures.fetch(next_frame) })
            @waiting.each { |pictures| pictures.delete(next_frame) } if @last_shown.fetch(next_frame) == @next_shown
            @next_shown += 1
          end
        end
      end

      # Each side in a process of its own. The sides are opened here, in order, as one after another
      # would open them; then each is played in a copy of this process (fork), which tells this one,
      # down a pipe, each shown frame's picture, made ready for the reel there (Widened), and its
      # sound. A side that answers `played_in_another_process` is told once every side's process has
      # started, and is closed here after: what it showed is the other process's. One thread here
      # reads each pipe, so no side waits on another to be read. A side that goes wrong stops every
      # side, and its error is raised here as it was there. However the play ends (a side's
      # process that could not start, an error or a timeout here), every side's process is stopped
      # and taken away before this returns, so none is left playing with nobody reading it.
      def play_sides_at_once(shown, dir, reel)
        opened = []
        plays = []
        listeners = []
        @sides.each_value.with_index { |opener, side| opened << open_side(opener, side) }
        opened.each_with_index { |running, side| plays << start_side_process(running, side, shown, dir) }
        opened.each { |running| running.played_in_another_process if running.respond_to?(:played_in_another_process) }
        listeners = plays.each_with_index.map do |(_pid, pipe), side|
          Thread.new do
            Thread.current.report_on_exception = false # raised again by #value, below
            listen_to_side(pipe, side, shown, reel)
          rescue StandardError
            stop_side_processes(plays)
            raise
          end
        end
        raise_first_side_failure(listeners)
      ensure
        listeners.each(&:kill)
        stop_side_processes(plays)
        plays.each { |pid, pipe| take_side_process_away(pid, pipe) }
        opened.each { |running| running.close if running.respond_to?(:close) }
      end

      # Waits for every side's thread, and raises the error a side stopped with: the one that went
      # wrong, rather than the sides stopped because of it (SideStopped).
      def raise_first_side_failure(listeners)
        failures = listeners.filter_map do |listener|
          listener.value
          nil
        rescue StandardError => e
          e
        end
        failure = failures.find { |error| !error.is_a?(SideStopped) } || failures.first
        raise failure if failure
      end

      # Every side's process stopped where it stands: one that has finished already is not there to stop.
      def stop_side_processes(plays)
        plays.each do |pid, _pipe|
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      # The ended process +pid+ waited for, so nothing of it is left, and its pipe closed.
      def take_side_process_away(pid, pipe)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      ensure
        pipe.close unless pipe.closed?
      end

      # A side's process ended without saying it had finished or what went wrong (it was stopped).
      class SideStopped < StandardError; end

      # Plays +running+ in a copy of this process, and answers its process id and the pipe it tells
      # this one down. A frame's sound goes as 64-bit numbers, so every sample arrives as the side
      # gave it, as it does where the sides play in one process.
      def start_side_process(running, side, shown, dir)
        pipe, told = IO.pipe
        pid = fork do
          pipe.close
          play_side(running, shown, side, dir) do |frame, shot, samples|
            Marshal.dump([:frame, frame, widened(shot), samples&.pack("q<*")], told)
          end
          Marshal.dump([:finished], told)
        rescue Exception => e # rubocop:disable Lint/RescueException -- every error is this process's last word
          Marshal.dump([:failed, sendable_error(e)], told)
        ensure
          told.close
          exit!(0) # not the test framework's or anyone's at_exit: this process is a side, nothing more
        end
        told.close
        [pid, pipe]
      end

      # +error+ as it can go down a pipe: itself, or where it cannot be written out (it holds a
      # block, say), a RuntimeError of the same words.
      def sendable_error(error)
        Marshal.dump(error)
        error
      rescue TypeError
        RuntimeError.new("#{error.class}: #{error.message}").tap { |copy| copy.set_backtrace(error.backtrace) }
      end

      def listen_to_side(pipe, side, shown, reel)
        loop do
          message = Marshal.load(pipe) # rubocop:disable Security/MarshalLoad -- written by this process's own copy
          case message
          in [:frame, frame, picture, samples] then arrived(side, frame, picture, samples&.unpack("q<*"), shown, reel)
          in [:finished] then return
          in [:failed, error] then raise error
          end
        end
      rescue EOFError
        raise SideStopped, "The side \"#{@sides.keys[side]}\" stopped before it had played every frame."
      ensure
        pipe.close unless pipe.closed?
      end

      # Every frame up to the last shown, with its buttons. Yields each shown frame's number, its
      # picture (a Shot) and its sound (nil where side number +side+ is not heard) once the picture
      # will not change, in order: a picture can be rescaled while every one before it is one colour
      # (#refuse_size_change!), so those wait for the first picture that is not, or for the side's
      # last.
      def play_side(running, shown, side, dir)
        heard = heard?(side)
        wanted = shown.to_set
        first_size = nil
        waiting = []
        settled = false
        (1..shown.max).each do |frame|
          running.step(1, keys: IR::Buttons.mask(@keys.call(frame)))
          # Asked every frame, shown or not: a lowering hands over the sound made since it was last asked.
          samples = running.last_frame_samples if heard
          next unless wanted.include?(frame)

          shot = shot_of(running, side, dir)
          size = [shot.width, shot.height]
          first_size ||= [frame, size]
          if size != first_size.last && !settled && waiting.all? { |(_, waited)| waited.one_color? }
            waiting.map! { |waited_frame, waited, sound| [waited_frame, waited.resized(*size), sound] }
            first_size = [frame, size]
          end
          refuse_size_change!(side, first_size, frame, size)
          waiting << [frame, shot, samples]
          settled ||= !shot.one_color?
          next unless settled

          waiting.each { |waited_frame, waited, sound| yield waited_frame, waited, sound }
          waiting.clear
        end
        waiting.each { |waited_frame, waited, sound| yield waited_frame, waited, sound }
      end

      # The picture +running+ shows now, as a Shot: from its `screen_picture` (copied, since a side
      # may draw over it), or where it answers only `screenshot`, from the PNG it writes in +dir+,
      # read back by ImageMagick.
      def shot_of(running, side, dir)
        if running.respond_to?(:screen_picture)
          picture = running.screen_picture
          return Shot.new(width: picture.width, height: picture.height, colours: picture.pixels.dup, rgb: nil)
        end

        path = File.join(dir, "side#{side}.png")
        running.screenshot(path)
        Film.shot_from_ppm(IO.popen([@commands.fetch(IMAGEMAGICK), path, "-depth", "8", "ppm:-"], "rb", &:read))
      end

      def widened(shot) = Widened.from(shot, @scale, @wide_channels)

      # A side that is heard hands over each frame's sound (FilmSound); one that cannot is refused.
      def refuse_side_without_sound!(running, side)
        return if running.respond_to?(:last_frame_samples)

        raise ArgumentError, "The side \"#{@sides.keys[side]}\" is heard, and it gives no sound: it does not answer " \
                             "`last_frame_samples`. To fix this, hear another side with `sound:`, or leave out `sound:`."
      end

      # A console that has shown nothing yet may be another size. Genesis Plus GX gives a Genesis
      # cartridge's first frame from power-on at the Master System's 256 x 192, the size its video chip
      # starts in, until the game sets it to its own; the picture is one colour, as nothing is shown yet.
      # While every picture taken of a side so far is one colour, they are the console before the
      # game's first picture: a change of size makes each of them the new size (still the one colour)
      # and the film goes on (#play_side).
      #
      # Once a side has shown something, its pictures are one size. A program that sets its screen to
      # another size as it plays (a PlayStation program can) cannot be filmed across the change.
      def refuse_size_change!(side, first_size, frame, size)
        first_frame, first = first_size
        return if size == first

        raise ArgumentError, "The picture of the side \"#{@sides.keys[side]}\" is #{first.join('×')} on frame " \
                             "#{first_frame} and #{size.join('×')} on frame #{frame}. The game changed the size of its " \
                             "screen, and a film shows one size. To fix this, film the frames before the change and " \
                             "the frames after it as two films."
      end

      # How many of the MP4's frames each shown frame is held for: one, and longer on each part's
      # last, with the film's last frame held until the film is long enough.
      def hold_lengths(shown)
        part_end = (PART_END_HOLD_SECONDS * FRAME_RATE).round
        ends = @parts.map(&:max) # max, not last: 1...10 ends on 9
        held = shown.map { |frame| ends.include?(frame) ? part_end : 1 }
        held[-1] += [(SHORTEST_FILM_SECONDS * FRAME_RATE) - held.sum, 0].max
        held
      end

      # The MP4 +out+: the MP4 of the film's pictures, +pictures+ (Reel), with +film_sound+ (FilmSound)
      # under them, the pictures shown once for each side heard in turn. The pictures are copied as
      # they are, not made again. The sound is exactly as long as the pictures.
      def add_sound(pictures, film_sound, dir, out)
        wav = film_sound.write_wav(File.join(dir, "sound.wav"))
        system(@commands.fetch(FFMPEG), "-y", "-loglevel", "error", "-stream_loop", (film_sound.showings - 1).to_s,
               "-i", pictures, "-i", wav, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
               out, exception: true)
      end

      # Each tool's command, found in +search_path+, or MissingTool naming every one not found.
      def find_commands!(tools, search_path)
        folders = search_path.split(File::PATH_SEPARATOR).reject(&:empty?)
        found = tools.to_h do |tool|
          [tool, tool.commands.lazy.map { |command| find_command(folders, command) }.find(&:itself)]
        end
        missing = found.select { |_, command| command.nil? }.keys
        raise MissingTool, missing_tools_message(missing) unless missing.empty?

        found
      end

      def find_command(folders, command)
        folders.map { |folder| File.join(folder, command) }.find { |path| File.file?(path) && File.executable?(path) }
      end

      def missing_tools_message(missing)
        names = missing.map(&:name).join(" and ")
        them = missing.size == 1 ? "it" : "them"
        installs = missing.map do |tool|
          "To install #{tool.name} on a Mac, run `brew install #{tool.package}`. " \
            "To install #{tool.name} on Linux, run `sudo apt install #{tool.package}`."
        end
        "A film needs #{names}. This computer does not have #{them}. #{installs.join(' ')} Then make the film again."
      end

      def refuse_bad_sides!(sides)
        return if sides.is_a?(Hash) && !sides.empty? && sides.each_value.all? { |opener| opener.respond_to?(:call) }

        raise ArgumentError, "`sides:` was #{sides.inspect}. Give a Hash of one side or more. Each key is the " \
                             "label of the side, and each value is a lambda that opens the cartridge: " \
                             "`sides: { \"ours\" => -> { Verifier.new(rom, frames: 0) } }`."
      end

      def refuse_bad_scale!(scale)
        return if scale.is_a?(Integer) && scale.positive?

        raise ArgumentError, "`scale:` was #{scale.inspect}. Give a whole number, 1 or more: `scale: 3` shows each " \
                             "picture at three times the size of the console's screen."
      end

      def refuse_bad_parts!(parts)
        good = parts.is_a?(Array) && !parts.empty? && parts.all? do |part|
          part.is_a?(Range) && part.begin.is_a?(Integer) && part.end.is_a?(Integer) && part.begin >= 1 && part.any?
        end
        return if good

        raise ArgumentError, "`parts:` was #{parts.inspect}. Give a list of frame ranges, counted from 1: " \
                             "`parts: [1..90, 200..240]`. Each range must hold one frame or more."
      end
    end
  end
end
