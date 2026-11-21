# frozen_string_literal: true

module VBlank
  module Live
    # A shell's unpacking split for several workers (Original::PiecedUnpacking), played on a Ractor
    # for each worker, each on a core of its own, away from the window. It answers what
    # Live::Session asks of a game, as BackgroundUnpacking does, and keeps what the shell keeps in
    # the same Outcome.
    #
    # The programs are the split's: the main one (the parts not in pieces) and each piece's, each
    # as its Ruby text (Backends::Ruby#live_source). They are jobs on a queue, the main one first
    # and then the pieces as the plan orders them (ShellFacts::PiecePlan#queue, the most work
    # first), and a worker that ends one is handed the next. Each worker makes a LiveGame for
    # each job afresh, so nothing one piece's game holds is another's; its class is made once
    # here for every worker (LiveGame.shareable_class says why).
    #
    # What crosses. A worker sends, at most once a frame's time, how many bytes its job has done
    # (its BYTES_DONE, read with LiveGame#vars, which reads no list), and the main job its picture
    # too: the words and the bar it draws of its own work. The window shows that picture with the
    # bar painted over it as far as every worker's work adds up to (PiecePlan#bar_width), in the
    # bar's own place and colours (ShellFacts::Bar). At its end a job sends its two numbers and
    # its bytes, and once every job has ended the pack is joined from them (PiecePlan#join), the
    # pieces in the order declared. Closing the window closes the way back, and each worker stops
    # at its next frame and keeps nothing.
    class WorkerUnpacking
      Outcome = BackgroundUnpacking::Outcome
      Facts = BackgroundUnpacking::Facts
      SILENCE = BackgroundUnpacking::SILENCE

      # One job: the class its game is made of (LiveGame.shareable_class), and the piece's number,
      # handed after the copy (nil for the main program).
      Job = Data.define(:game_class, :number)

      # +sources+ are every worker program as Ruby, which +plan+ (a ShellFacts::PiecePlan) numbers
      # its main program and each piece's program by; +copy+ the copy's bytes; +names+ the
      # unpacking's names a shell reads (ShellFacts::UnpackingNames); +bar+ the bar's look
      # (ShellFacts::Bar); +workers+ how many Ractors play the jobs, at most one a job. The workers
      # start here, and this waits for the main job's game to be made.
      def initialize(sources, copy, names, plan:, bar:, workers:)
        @plan = plan
        @bar = bar
        # Each job: its program's class, and the piece's number (nil for the main program). The
        # main job is 0, and piece i of the plan is job i + 1.
        classes = {}
        made = ->(program) { classes[program] ||= IR::Backends::Ruby::LiveGame.shareable_class(sources.fetch(program)) }
        @jobs = [Job.new(game_class: made.call(plan.main), number: nil),
                 *plan.pieces.map { |piece| Job.new(game_class: made.call(piece.program), number: piece.number) }]
        @results = Ractor::Port.new
        @inbox = Thread::Queue.new
        @queue = [0, *plan.queue.map { |piece| piece + 1 }]
        @done = Array.new(@jobs.length, 0)
        @ended = Array.new(@jobs.length)
        @main_picture = nil
        @facts = nil
        shared_copy = Ractor.make_shareable(copy.frozen? ? copy : copy.dup.freeze)
        shared_names = Ractor.make_shareable(names)
        @workers = Array.new([workers, @jobs.length].min) { start_worker(shared_copy, shared_names) }
        @receiver = Thread.new { receive_results }
        @workers.each { |worker| hand_next_job(worker) }
        take_message(nil) until @facts
      end

      def width = @facts.width
      def height = @facts.height
      def sound_rate = @facts.sound_rate
      def frame_seconds = @facts.frame_seconds

      # As BackgroundUnpacking's: no players, no save memory.
      def seats = 0
      def save_size = 0
      def save_file_due? = false
      def save_unwritten? = false

      # What the jobs left, joined (Outcome), once #play has given back a picture.
      attr_reader :outcome

      # Shows +player+ the main job's newest picture with the whole bar over it, each frame, until
      # every job has ended, when it gives back the last picture, or the player stops it, when it
      # gives back nil.
      def play(player, match_seed: nil, local_player: nil) # rubocop:disable Lint/UnusedMethodArgument -- what Session hands a game
        loop do
          take_message(frame_seconds)
          if @ended.all?
            @outcome = joined_outcome
            shown = picture_shown
            player.buttons_after(shown, SILENCE, SILENCE)
            return shown
          end
          return nil if player.buttons_after(picture_shown, SILENCE, SILENCE).nil?
        end
      ensure
        stop_workers
      end

      private

      # One worker: it plays each job it is handed until it is handed :stop, sending what it does
      # to +results+ as the top of this class says.
      def start_worker(copy, names)
        results = @results
        quiet_experimental_warning do
          Ractor.new(copy, names, results) do |bytes, names, results|
            loop do
              job = Ractor.receive
              break if job == :stop

              index, game_class, number = job
              game = IR::Backends::Ruby::LiveGame.new(nil, game_class: game_class)
              # A piece's program is handed the piece's number after the copy (PlannedPiece#start_file).
              game.hand_file(number ? Original::ShellFacts.piece_start_file(bytes, number) : bytes)
              if index.zero?
                results << [:facts, Facts.new(width: game.width, height: game.height, sound_rate: game.sound_rate,
                                              frame_seconds: game.frame_seconds)]
              end
              sender = WorkSender.new(results, game, index, names.bytes_done)
              last = game.play(sender)
              break if last.nil?

              vars = game.vars
              state = game.state(byte_lists_packed: true)
              results << [:ended, Ractor.current, index, vars.fetch(names.finished), vars.fetch(names.fault_kind),
                          state.lists.fetch(names.bytes).b, (last if index.zero?)]
            end
          rescue Ractor::ClosedError
            nil # the window stopped listening
          rescue StandardError => e
            begin
              results << [:failed, Ractor.current]
            rescue Ractor::ClosedError
              nil
            end
            raise e
          end
        end
      end

      # Ruby warns that Ractors are experimental the first time one starts (BackgroundUnpacking
      # says why that line is left out).
      def quiet_experimental_warning
        was = Warning[:experimental]
        Warning[:experimental] = false
        yield
      ensure
        Warning[:experimental] = was
      end

      # The next job on the queue handed to +worker+, or :stop where none is left.
      def hand_next_job(worker)
        index = @queue.shift
        worker << (index.nil? ? :stop : [index, @jobs.fetch(index).game_class, @jobs.fetch(index).number])
      rescue Ractor::ClosedError
        nil # the worker has ended
      end

      # What the window sends itself to end #receive_results.
      STOP_RECEIVING = :stop_receiving

      def receive_results
        while (message = @results.receive) != STOP_RECEIVING
          @inbox << message
        end
      end

      # One message from the workers, waiting up to +seconds+ for it (nil: as long as it takes),
      # taken in: a count of bytes done, the main job's picture, its game's facts, or a job's end,
      # when the worker is handed the next. A worker that failed raises what it failed with.
      def take_message(seconds)
        case @inbox.pop(timeout: seconds)
        in [:progress, index, done] then @done[index] = done
        in [:picture, pixels] then @main_picture = pixels
        in [:facts, facts] then @facts = facts
        in [:ended, worker, index, finished, fault_kind, bytes, last]
          # An ended job's share is whole: a routine counts the bytes its blocks and decoders
          # write, and not each one it sets alone (a song's length), as the whole routine's bar
          # is whole once it has finished.
          @done[index] = index.zero? ? @plan.main_bytes : @plan.pieces.fetch(index - 1).bytes
          @ended[index] = Outcome.new(finished: finished, fault_kind: fault_kind, bytes: bytes)
          @main_picture = last if last
          hand_next_job(worker)
        in [:failed, worker]
          raise_failure(worker)
        in nil then nil
        end
      end

      # The error +worker+ stopped with, raised as it was, with no cause (BackgroundUnpacking's
      # #collect_outcome says why).
      def raise_failure(worker)
        worker.value
        raise ArgumentError, "An unpacking's worker stopped, and it gave no reason."
      rescue Ractor::RemoteError => e
        raise e.cause, cause: nil
      end

      # The main job's newest picture (black until it draws one) with the bar over it as far as
      # every job's work adds up to.
      #
      # Must not make a new picture each frame: every Ractor stops while Ruby collects garbage, so
      # a window that made one a frame slowed the workers. One is kept and drawn over.
      def picture_shown
        shown = (@shown ||= Array.new(width * height, 0))
        shown.replace(@main_picture) if @main_picture
        across = width - (2 * @bar.side)
        top = (height - @bar.height) / 2
        filled = @plan.bar_width(@done, across)
        @bar.height.times do |row|
          start = ((top + row) * width) + @bar.side
          shown.fill(@bar.filled, start, filled)
          shown.fill(@bar.empty, start + filled, across - filled)
        end
        shown
      end

      # Every job's two numbers taken together, the first fault in the order the programs are
      # declared, and the pack joined from their bytes.
      def joined_outcome
        finished = @ended.all? { |ended| ended.finished == 1 } ? 1 : 0
        fault = @ended.map(&:fault_kind).find(&:nonzero?) || 0
        bytes = @ended.map(&:bytes)
        Outcome.new(finished: finished, fault_kind: fault, bytes: @plan.join(bytes.first, bytes.drop(1)))
      end

      # The window stops listening, once, and every worker is told to stop: one playing a job finds
      # the way closed at its next frame, and one waiting for a job takes :stop.
      def stop_workers
        return if @results.closed?

        @results << STOP_RECEIVING
        @receiver.join
        @results.close
        @workers.each do |worker|
          worker << :stop
        rescue Ractor::ClosedError
          nil
        end
        wait_for_idle_workers if @ended.all?
      end

      # Once every job has ended, each worker is waiting for its next, so :stop ends it at once:
      # waited for here, nothing of the unpacking is left running when the play returns. A program
      # that copies its process next (a film plays each side in a copy, Diagnostics::Film) copies
      # one with no Ractor but its own. A worker stopped part way through a job is not waited for:
      # it ends at its next frame, and a window closing should not wait on that.
      def wait_for_idle_workers
        @workers.each do |worker|
          worker.join
        rescue Ractor::RemoteError
          nil # raised already, where its job failed
        end
      end

      # Who plays a job in its worker: it holds no buttons, and at most once every SEND_SECONDS
      # sends how many bytes the job has done, and the main job (+index+ 0) its picture. Once the
      # window has closed the way, it stops the play.
      #
      # Not every frame: reading the count reads every variable of the game (LiveGame#vars), and
      # a picture is a copy for another Ractor, which in a long unpacking added up to a share of
      # the work. A bar moved a few times a second looks no different. So the picture is asked for
      # only on a frame it is sent, and only by the main job, and no job asks for sound: the
      # runtime builds neither on the other frames (LiveGame says how it is asked).
      class WorkSender
        NO_BUTTONS = [].freeze
        SEND_SECONDS = 0.1

        def initialize(results, game, index, bytes_done)
          @results = results
          @game = game
          @index = index
          @bytes_done = bytes_done
          @sent_at = nil
          @picture_sent_at = nil
        end

        def take_state_request = nil
        def sound_wanted? = false
        def picture_wanted? = @index.zero? && due?(@picture_sent_at, now)

        # +pixels+ is the picture where #picture_wanted? asked for it, else nil.
        def buttons_after(pixels, _left, _right)
          at = now
          if due?(@sent_at, at)
            @results << [:progress, @index, @game.vars.fetch(@bytes_done)]
            @sent_at = at
          end
          if pixels
            @results << [:picture, pixels]
            @picture_sent_at = at
          end
          NO_BUTTONS
        rescue Ractor::ClosedError
          nil
        end

        private

        def due?(sent_at, at) = sent_at.nil? || at - sent_at >= SEND_SECONDS
        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
