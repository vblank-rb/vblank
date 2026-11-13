# frozen_string_literal: true

module VBlank
  module Console
    # WHAT EVERY VERB DOES ON A CONSOLE, decided once for each console and written down in a table
    # of its own (Console::AdvanceAnswers, Console::ColorAnswers), where the build checks and the
    # reference both read it. Every verb gets one of two answers:
    #
    # - :works — the same game, played the same way. Each lowering's run of the suite holds the
    #   game to the interpreter, so this is a promise the test suite keeps.
    # - :refused — the build stops before anything is made, naming the hardware the console lacks
    #   and what to use instead.
    #
    # NOTHING IS SHOWN DIFFERENTLY. A turned layer shown unturned, a mosaic left sharp: each is a
    # game that looks right on one console and quietly wrong on the other, which a teaching tool
    # must not ship. What a console's hardware cannot do, the author hears about while building,
    # not while playing.
    #
    # A verb that works may still have a part the console lacks — the Color reads `held`, but not
    # for a shoulder button it does not have. Which part a line asks for is Console::Questions's
    # to work out, from the console's description; the verb's answer has the words it is refused
    # in. #refusals puts the two together for a whole program, and it is the one place that does:
    # the build's checks report it, and each lowering asks it of a program handed to it straight.
    #
    # A console's table is a module that extends this one and holds:
    #
    #   ANSWERS     every verb a game can write, to its Answer. A test holds it to the builder, so a
    #               new verb has no answer on any console until somebody decides one
    #   PLAIN       what a verb that works answers when it has nothing more to say
    #   PAGE        the file under .claude/dsl/ that is the table written out
    #   reference   the text of PAGE, asked for through the console's kit (Kit#answers_page),
    #               which hands it anything the page names from the console's build.
    #               `ruby tools/console_answers.rb` writes it, and a test fails when the two
    #               differ, so the reference cannot say one thing while the build does another
    module Answers
      Answer = Data.define(:verdict, :words) do
        def works? = verdict == :works
        def refused? = verdict == :refused
      end

      VERDICTS = %i[works refused].freeze

      # The answer every console gives for what only a computer's window reads.
      COMPUTER_ONLY = "they are for the game built for a computer (the window, `vblank run`, the web page): " \
                      "the cartridge is built byte for byte as without it."

      # What a shade between the speakers (`pan -0.7`, Audio::Pan) does on the square, wave and noise
      # voices, which switch each speaker on or off and have nothing between: the same on every console.
      # A sentence of its own, so it can follow whatever an answer says first (PAN_LEAD, where nothing
      # else does).
      NEAREST_SIDE = "A square, wave or noise part between the speakers (`pan -0.7`) plays from one " \
                     "speaker if that side is two or more times as loud as the other side. If not, it " \
                     "plays from both speakers."

      # The start of an answer that says nothing else first.
      PAN_LEAD = "a part can sit between the speakers."

      # ...and what it does on a recorded part where every recording is mixed into one sound. Both
      # follow NEAREST_SIDE, so each starts a sentence.
      RECORDINGS_FROM_BOTH = "A part that plays a recording plays from both speakers, wherever `pan` puts " \
                             "it: all recordings are mixed into one sound, and both speakers play it."

      # ...and where each voice of the sound chip has a volume for each speaker.
      RECORDINGS_WHERE_PANNED = "A part that plays a recording is heard where `pan` puts it: each voice " \
                                "of the sound chip has a volume for the left speaker and one for the right."

      # What a Score note's own rattle and its own waveform do (Audio::Score::Note#metallic, #wave), a
      # sentence of its own: played as the note starts, or on a console whose player puts a new music
      # volume on a held note from the part's own settings, refused where the game sets that volume.
      NOTE_VOICES = "A note on the noise voice can have its own `metallic:`, and a note on the wave voice can " \
                    "have its own `wave:`. The note sets them when it starts."
      NOTE_VOICES_NOT_UNDER_VOLUME = "#{NOTE_VOICES} If the game sets its music volume, such a note is refused: " \
                                     "this build does not make it yet."

      # How the reference names each verdict.
      VERDICT_WORDS = { works: "works", refused: "**refused**" }.freeze

      # An answer that works, in +words+, or in the table's own (PLAIN) for a verb with nothing
      # more to say.
      def works(words = self::PLAIN) = Answer.new(:works, words)

      def refused(words) = Answer.new(:refused, words)

      # The answer for +verb+, or nil for a verb nobody has decided yet.
      def answer(verb) = self::ANSWERS[verb.to_sym]

      # A line a console cannot do, and the words it is refused in.
      Refusal = Data.define(:node, :words)

      # An answer that only points at another verb's: "see `pixelate`."
      SEE_ANOTHER = /\Asee `([a-z_]+\??)`\.\z/

      # The words +verb+ is answered in. An answer that only points at another verb's (SEE_ANOTHER)
      # is that verb's words, so a refusal says why and never "see" something the author cannot
      # look up from a build's output.
      def words_of(verb)
        words = answer(verb).words
        pointed = words[SEE_ANOTHER, 1]
        pointed && answer(pointed) ? words_of(pointed) : words
      end

      # EVERY LINE OF +nodes+ (a program's steps) THAT +console+ CANNOT DO, as Refusals in this
      # table's words, in the program's order. Empty for a program the console plays.
      #
      # A verb the game wrote that is made of another verb's steps (Questions::WRITTEN_VERBS) is
      # refused first, in its own answer's words, and the lines of the verb underneath are then
      # passed over: they would say the same thing again in words about something the author did
      # not write.
      def refusals(nodes, console)
        nodes = nodes.to_a
        written = nodes.select { |node| node.kind == :program }.flat_map do |program|
          Questions.verb_questions(program).reject { |question| answer(question.verb).works? }
                   .map { |question| [question.verb, Refusal.new(program, refusal_words(question, console))] }
        end
        stood_in_for = written.filter_map { |verb, _| Questions.made_of(verb) }
        written.map(&:last) + nodes.filter_map do |node|
          question = Questions.question_for(node, console) or next
          verdict = answer(question.verb)
          next if question.can.nil? ? verdict.works? : question.can
          next if stood_in_for.include?(question.verb)

          Refusal.new(node, refusal_words(question, console))
        end
      end

      def refusal_words(question, console)
        "#{question.words}, and a #{console.title} cannot: #{words_of(question.verb)}"
      end

      # The reference's line for the answer to each verb in +verbs+, in the order ANSWERS gives them.
      def answer_lines(verbs = self::ANSWERS.keys)
        verbs.map do |verb|
          answer = self::ANSWERS.fetch(verb)
          "- `#{verb}` — #{VERDICT_WORDS.fetch(answer.verdict)}: #{answer.words}"
        end
      end
    end
  end
end
