# frozen_string_literal: true

module VBlank
  module Messages
    # THE FIRST LINE OF A BUILD THAT STOPPED. A build that stops prints why, and the why is often a
    # long paragraph about one line of the game. Read on its own, straight after the phases of the
    # build, it does not say whether the build went on: a warning reads the same way. So whatever
    # prints a stopped build's reason (the build itself, for the guardrails' findings it prints; the
    # command line, for the reason it ends with) puts this line above it, then a blank line.
    #
    # It is a status line, seen once at the end of a build, so it is short and reads like a label.
    module BuildStopped
      # "Build stopped: WOLF3D has a problem to fix. Nothing was built, and nothing will play."
      #
      # +console+ is the console's title, for a game built for several consoles one after the
      # other: the others can still build, so the line says which one did not.
      def self.headline(title, console: nil)
        return "Build stopped: #{title} has a problem to fix. Nothing was built, and nothing will play." unless console

        "Build stopped: #{title} for the #{console} has a problem to fix. Nothing was built for that console."
      end

      # The headline, a blank line, then +explanation+ as it was.
      def self.with_headline(explanation, title, console: nil) = "#{headline(title, console: console)}\n\n#{explanation}"

      # The line a build the guardrails stopped ends with, under the findings it printed: the
      # findings are the explanation, so this says only what to do.
      def self.fix_findings_line(problems)
        "Fix the #{problems == 1 ? 'problem' : "#{problems} problems"} above. Then build again."
      end
    end
  end
end
