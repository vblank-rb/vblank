# frozen_string_literal: true

module VBlank
  module Cartridge
    # The cartridge of a console whose lowering is checked by a run of its own — the Game Boy
    # Color's, the Super Nintendo's, the Genesis's and the PlayStation's — made from a checked
    # program by the lowering its kit names (Console::CheckedKit#lowering). One build serves every
    # such console: the lowering is what differs, and the kit names it.
    #
    # The build lowers the program, adds what the lowering found to the build's findings, and lists
    # any routine the game asked to see (`dump_func`) with the lister the kit names
    # (Console::Kit#routine_lister). Where the console's answers refuse that listing, the build
    # refuses it in their words. A request to list belongs to the build, not to a step of the
    # program, so it is checked here and not with the program's lines (Console::Answers#refusals).
    LoweredBuild = Data.define(:kit) do
      # The cartridge for +request+ (a Cartridge::BuildRequest). What the lowering had to say about
      # what it decided joins the findings, so it is printed with the rest.
      def build(request)
        dumps = request.evaluated.dump_requests
        if !dumps.empty? && kit.answers.answer(:dump_func).refused?
          raise ROMError, "This game lists a routine's code (`dump_func #{dumps.first.inspect}`), and a " \
                          "#{kit.title} cannot: #{kit.answers.words_of(:dump_func)} Take out " \
                          "`dump_func`, or build for the Game Boy Advance alone to see it."
        end

        request.progress.step("Compiling for the #{kit.title}")
        lowering = kit.lowering.new
        cartridge = lowering.build(request.program, title: request.title)
        if request.findings
          request.findings = request.findings.with(findings: request.findings.findings + lowering.findings)
        end
        kit.routine_lister.new(cartridge, out: request.out, err: request.err).dump(dumps) unless dumps.empty?
        cartridge
      end

      # The cartridge for +program+ alone, titled +title+. What a test that plays a cartridge
      # builds (Testing::Pictures).
      def cartridge_for(program, title:) = kit.lowering.new.build(program, title: title)
    end
  end
end
