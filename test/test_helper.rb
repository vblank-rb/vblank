# frozen_string_literal: true

# Coverage measurement is opt-in (COVERAGE=1 rake test) — a plain run pays nothing for it.
# The whole suite is one process now, so there is one result and nothing to stitch together.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  require_relative "support/coverage"

  SimpleCov.start(&Coverage::FILTERS)
end

# The library's test helper, the one a game's own suite requires: minitest, the library, and
# which lowering this run tests. This suite uses it as a game does, so the two cannot drift.
require_relative "../lib/vblank/testing"
require_relative "../lib/vblank/testing/in_ractors"
require "support/suites"

# The one require a test file needs. It pulls in minitest and the library, and
# hands every test the names and helpers that nearly all of them want, so a test
# file can open with the thing it is actually testing.
#
# The short names below. A test says `Builder.new` and `Color.resolve(:red)`
# rather than spelling out VBlank::… every time. They used to be re-declared at
# the top of all 93 test files, which meant renaming one of them touched every
# file; now they live here.
#
# A file that wants a name for something else of its own just declares it — a
# constant in the file wins over one from here (test_cost_printer.rb points
# `Color` at the printer's palette that way).
module SharedConstants
  Reference = VBlank::IR::Backends::Reference # the oracle: runs a program in-process
  SaveImage = VBlank::IR::SaveImage           # a cartridge's save memory, which outlives a run
  GBA = VBlank::IR::Backends::GBA             # the lowering: turns a program into a ROM
  Builder = VBlank::Builder                   # the DSL surface
  Color = VBlank::Graphics::Color
  ROM = VBlank::Cartridge::ROM

  # A solid 8x8 tile of one color — the piece of art a tiled test needs before it can say
  # anything about scrolling, layers, collision or sprites. Twenty-six files had written it
  # out for themselves, under five different names and in two spellings that differed by a
  # trailing newline, so a test reading two of them was comparing things that were not quite
  # the same. It is here once now.
  #
  # Shareable, like everything else here: a test may run in a Ractor, and a worker can read a
  # constant only when nothing in it can change. See test/all/vblank/test_ractor_safety.rb.
  SOLID_TILE = Ractor.make_shareable((["########"] * 8).join("\n"))
end

# Every IR node class by its bare name, so a test that builds a tree by hand says
# `Case.new(clauses: ...)` rather than spelling out the namespace each time.
#
# OPT-IN, like the other narrower helpers: there are eighty-odd of these and some of the
# names are ones a test may want for something else (Table, Sample, Screen). A file that
# builds nodes directly includes it; everything else never sees them.
module NodeTypes
  VBlank::IR::Nodes.constants.each do |name|
    const_set(name, VBlank::IR::Nodes.const_get(name))
  end
end

# Two IR trees of the same shape. A node is equal only to itself, so a test that builds the
# tree it expects compares contents by asking for it; the diff on failure is the two trees
# as nested hashes.
module TreeAssertions
  def assert_same_shape(expected, actual, message = nil)
    assert_equal expected.to_h, actual.to_h, message
  end
end

# Shared helpers for tests that exercise the emulator in-process. The emulator backend
# (ruby-gba-emulator, a headless libmgba probe) is reached through VBlank::Diagnostics::Emulator — the one
# seam — so nothing here names it directly.
#
# Include this in a test class instead of copy-pasting begin/require/rescue
# blocks or per-test availability guards.
module EmulatorSupport
  # Whether the in-process emulator core can be loaded — for the standalone
  # debug scripts that degrade gracefully. Suite tests use #require_emulator!,
  # which fails loud, since the emulator is required, not optional.
  def self.gem_available?
    VBlank::Diagnostics::Emulator.available?
  end

  # Ensure the emulator is available, failing loudly if it isn't. It is required to verify
  # ROMs, so a missing build is a real error, not a reason to silently skip and pass with the
  # coverage gutted. `rake test` builds it first; run `rake test:emulator` to build it by hand.
  #
  # A test that reaches for the emulator this way reads the Game Boy Advance's cartridge, which is
  # the GBA lowering's output, so it lives in test/lowering/gba/ and no other run loads it.
  # Reached on another run, it is a test in the wrong folder, and it fails saying so. (A native
  # run does use the emulator for one thing — as the answer key for the desktop build's sound —
  # and asks it directly, not through here: see test/sound_comparison.rb.)
  def require_emulator!
    if VBlank::Testing.checked?
      flunk "this test reads the Game Boy Advance's cartridge on the #{VBlank::Testing::RUN.title} run. To fix " \
            "this, move it to test/lowering/gba/, which only the GBA lowering's run loads."
    end

    VBlank::Diagnostics::Emulator.load!
  end

  # Lower an IR program to a finished ROM, the way the emulator tests need it — a
  # convenience over repeating ROM.assemble(GBA.new.lower(prog), title:, code:,
  # maker:) in every test. The header fields don't affect rendering, so they
  # default; pass +name+ just to label the ROM.
  #
  # The ROM carries its build record, so a test can ask the running cartridge about what the
  # build decided — what it is playing (Verifier#voices), where its variables are — without
  # holding on to the backend that lowered it.
  def assemble_rom(program, name: "TEST")
    VBlank::Cartridge::AdvanceBuild.cartridge_for(program, title: name)
  end

  # Load +rom+ into the emulator and run it headless for +frames+ frames,
  # asserting it loads and runs without raising. Fails loudly if the emulator isn't
  # built (it's required). Returns a VBlank::Diagnostics::Verifier so callers can make pixel
  # assertions on the rendered frame:
  #
  #   v = assert_emulator_loads_rom(rom, frames: 30)
  #   assert v.red?(120, 80)
  def assert_emulator_loads_rom(rom, frames: 10, **opts)
    require_emulator!
    verifier = VBlank::Diagnostics::Verifier.new(rom, frames: frames, **opts)
    verifier.pixel(0, 0) # force the emulator to load the ROM and run the frames
    verifier
  rescue StandardError => e
    flunk "the emulator failed to load/run ROM after #{frames} frames: #{e.class}: #{e.message}"
  end
end

# Hand the above to every test, without each one asking.
#
# Reopening Minitest::Test is how a Minitest suite does what RSpec spells
# `config.include` — every test class already inherits from it, so a module
# included here reaches all of them. Ruby looks a constant up through the
# ancestors of the class it is used in, so `Reference` and `Color` resolve inside
# any test with nothing declared in the file.
#
# It IS a monkey-patch of somebody else's class, which is worth knowing. The
# alternatives are a base class every test has to remember to inherit from, or
# the per-file boilerplate this replaces. RSpec effectively does this too.
#
# Deliberately only the two that nearly every file wants. Narrower helpers stay
# opt-in — a file that needs `Differential` or `CostArith` includes it — so those
# names appear only where they are used and cannot collide across the suite.
class Minitest::Test # rubocop:disable Style/ClassAndModuleChildren
  include SharedConstants
  include EmulatorSupport
  include TreeAssertions
  include VBlank::Testing # game_player, skip_on_native and CheckedPlayer, as a game's suite has them

  # Every test in the pool and every fixture in a constant frozen all the way down: the same line a
  # game's test helper has (Testing::InRactors says why each is what it is). A file whose tests
  # change the whole process on purpose says minitest-ractor's `runs_on_the_main_ractor!`. Anything
  # that refuses to freeze is named by test/all/vblank/test_ractor_safety.rb rather than passing
  # quietly.
  include VBlank::Testing::InRactors
end
