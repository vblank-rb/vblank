# frozen_string_literal: true

module VBlank
  module Playthroughs
    # A PLAYTHROUGH ON ANOTHER WAY OF RUNNING A GAME than the emulator: the interpreter, or the game
    # built as C, as JavaScript played by node, or as Ruby, or its rules alone (Native::RulesRun).
    # It answers what a playthrough asks of a running game (a frame played, a number read) the way
    # the emulator's reader does, so a script and its steering blocks need no change. Each of these
    # runs a game from start to end, asking for each frame's buttons as it goes, so the run sits in
    # a Fiber, stopped at that question, and each frame played is one answer.
    #
    # Two runs are not the same run. A frame on the console and a frame here are different moments
    # in a game that takes longer than a frame over a pass, so a script of counted frames can come
    # out differently, and one that watches or steers finishes all the same. Each repeats itself.
    class LoweredGame
      # The way that plays the cartridge itself, which is no LoweredGame.
      EMULATOR = "emulator"

      # The way with nothing to see or hear, for a bot playing one long run many times.
      LOGIC = "logic"

      # The ways, by the word `on:` takes, and the run each is (`vblank run --on` uses "js" for "web":
      # see CommandLine::WAYS).
      RUNS = { "interpreter" => -> { IR::Backends::Reference }, "native" => -> { IR::Backends::Native::HeadlessRun },
               "web" => -> { IR::Backends::JS::HeadlessRun }, "ruby" => -> { IR::Backends::Ruby::HeadlessRun },
               LOGIC => -> { IR::Backends::Native::RulesRun } }.freeze

      def self.ways = [EMULATOR, *RUNS.keys]

      # More frames than any playing gets to: the playing decides when it is over (#finish).
      UNENDING = 1 << 30

      # Raised into the run's Fiber to end a run the playing has finished with.
      class Finished < StandardError; end

      # +speaker+ marks that somebody is listening, so a way that makes its sound as a file hands it over
      # a frame at a time (#last_frame_samples).
      def initialize(program, way, speaker: false)
        @console = program.described_console
        @run = RUNS.fetch(way).call.new
        @run.forgetting_moments if @run.respond_to?(:forgetting_moments)
        @speaker = speaker && @run.respond_to?(:sounding_as_played)
        @run.sounding_as_played if @speaker
        @held = []
        @frames = 0
        @run.input_each_frame do
          Fiber.yield
          @held
        end
        @fiber = Fiber.new do
          @run.run(program, frames: UNENDING)
        rescue Finished
          nil
        end
        @fiber.resume # to the first frame's question: the game has not played a frame yet
      end

      # Play +count+ frames with the buttons of the mask +keys+ down. A game that has ended stays
      # where it ended, as a console does.
      def step(count = 1, keys: nil)
        @held = pressed(keys) if keys
        count.times do
          next unless @fiber.alive?

          @fiber.resume
          @frames += 1 if @fiber.alive?
        end
        self
      end

      # How many passes of the game loop have finished: every way here plays a pass a frame, and a
      # game that has ended finishes no more.
      def passes = @frames

      # :yjit or :none, as the Ruby that plays a game built as Ruby reports of itself; nil for a way that
      # does not report it (the interpreter runs in this Ruby, C needs no compiler, node's is always on).
      def running_jit = (@run.running_jit if @run.respond_to?(:running_jit))

      def var(name) = @run.var(name)
      def raw_var(name) = @run.raw_var(name)
      def sprite(name) = @run.sprite(name)
      def background(name) = @run.background(name)
      def music_volume = @run.music_volume
      def list(name) = @run.list(name)
      def pool(name, field) = @run.pool(name, field)
      def screen_width = @console.screen_width
      def screen_height = @console.screen_height
      def frame_gba = @run.screen.shown

      # The picture on screen written as a PNG at +path+, which is handed back, as the emulator's reader
      # writes one (Diagnostics::Verifier#screenshot): a film is made of these.
      def screenshot(path)
        Graphics::PNG.write(path, width: screen_width, height: screen_height, pixels: frame_gba)
      end

      # The run stopped, as a film closes a side whose frames it has taken.
      def close = finish

      # The sound of the frames just played, the two speakers' samples a moment at a time, and how
      # many moments a second that is; nothing and nil where nobody is listening or the way has none.
      def last_frame_samples = @speaker ? @run.last_frame_samples : []
      def sound_rate = (IR::Backends::Native::HeadlessRun::SOUND_RATE if @speaker)

      # These runs keep no save memory a playthrough can take away.
      def save_bytes = nil

      # A playing that has finished, the run stopped where it stands.
      def finish
        @fiber.raise(Finished) if @fiber.alive?
      end

      private

      def pressed(keys) = Playthrough.pressable_buttons.select { |button| keys.anybits?(Playthrough.key_mask([button])) }
    end
  end
end
