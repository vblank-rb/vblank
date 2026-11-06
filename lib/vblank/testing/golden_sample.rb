# frozen_string_literal: true

module VBlank
  module Testing
    # THE GOLDEN PATH'S RANDOM PART. `rake test:golden` plays the files its list names, which are
    # chosen by hand and the same every day, and a share of the other test files drawn at random,
    # different on every run. So over many days the everyday run touches the whole suite, while
    # any one run stays short.
    #
    # A draw that found a fault must be playable again, so the draw comes from a seed, and the run
    # says it at the start and at the end: GOLDEN_SEED=<seed> plays the same files again.
    #
    # There is no time limit. The list itself is kept small by a test of its own
    # (test/all/vblank/testing/test_golden.rb in this repository), and the share is a share, so the
    # run grows only as the suite does.
    #
    # RakeTasks and GoldenTask draw with it. A game that keeps a rake of its own draws alone, with
    # nothing else of the library's loaded:
    #
    #   require "vblank/testing/golden_sample"
    #   draw = VBlank::Testing::GoldenSample.draw(all_test_files - golden_files)
    #   puts draw.message
    #   play(golden_files + draw.files)
    module GoldenSample
      # The share of the test files not on the list that each run draws.
      SHARE = 0.05
      SEED_SETTING = "GOLDEN_SEED"
      # Seeds are drawn below this, so one is short enough to type.
      MOST_SEED = 1_000_000

      # The files drawn, out of how many there were to draw from, and the seed that drew them.
      Draw = Data.define(:files, :drawn_from, :seed) do
        def message
          "The golden path drew #{files.size} of #{drawn_from} more test files at random. " \
            "To play the same ones again, set #{SEED_SETTING}=#{seed}."
        end
      end

      module_function

      # +share+ of +files+, at least one while there is any to draw and the share is above nothing,
      # drawn from the seed GOLDEN_SEED in +env+ names, or a new one.
      def draw(files, share: SHARE, env: ENV)
        seed = seed_from(env)
        pool = files.uniq.sort
        count = (pool.size * share).ceil
        Draw.new(files: pool.sample(count, random: Random.new(seed)).sort, drawn_from: pool.size, seed: seed)
      end

      def seed_from(env)
        given = env[SEED_SETTING]
        return Random.new_seed % MOST_SEED if given.nil? || given.empty?

        Integer(given, 10)
      rescue ArgumentError
        abort "#{SEED_SETTING} is #{given.inspect}, and it must be a whole number. " \
              "Use the number a golden run printed, or remove #{SEED_SETTING} to draw new files."
      end
    end
  end
end
