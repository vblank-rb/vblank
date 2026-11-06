# frozen_string_literal: true

module VBlank
  module DSL
    # A STEP AN EFFECT TAKES ONCE A PASS, from when the game starts it until it stops. Builder
    # #each_pass makes one.
    #
    #   walk = each_pass(:iris_walk) do |job|
    #     light.radius -= 4
    #     if light.radius <= 0
    #       light.radius = 0
    #       job.stop
    #     end
    #   end
    #   walk.start     # the first step now, on this pass, then one every pass after
    #
    # Once a PASS of the game loop, not once a frame: a pass that takes three frames takes one
    # step, the way a game counting its own passes steps its effects. `once_a_frame` is the
    # other one, for an effect timed in real time.
    class PassJob
      # Built by Builder#each_pass: the routine that takes one step, the variable that holds
      # whether the job is running, 1 or 0, and the one that holds whether a step is being taken
      # right now.
      def initialize(builder, routine:, running:, stepping:)
        @builder = builder
        @routine = routine
        @running = running
        @stepping = stepping
      end

      # Start the job: its first step is taken here and now, as part of this pass, and one more
      # every pass after until it stops. A job already running is left as it is. Started from
      # inside its own step, it takes the next step on the next pass, not at once again.
      def start
        if @running == 0
          @running = 1
          # Written inside the step itself, the step is always being taken when this runs, so
          # the call is left out rather than written under a test that never passes: a step
          # that names its own routine reads as a routine that calls itself, which a console
          # keeping each routine's numbers at fixed places cannot make.
          unless @step_being_built
            @builder.call(@routine) if @stepping == 0
          end
        end
        self
      end

      # Build the job's own step: Builder#each_pass runs the block that writes it inside this.
      def with_step_being_built
        @step_being_built = true
        yield
      ensure
        @step_being_built = false
      end

      # Stop the job: it takes no more steps until it starts again. A step that stops its own job
      # finishes the step it is on.
      def stop
        @running = 0
        self
      end

      # Whether the job is running, as a test the game can branch on.
      def running? = @running == 1
    end
  end
end
