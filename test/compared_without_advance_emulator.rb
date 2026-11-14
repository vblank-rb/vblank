# frozen_string_literal: true

require "open3"
require "tmpdir"

# TWO CARTRIDGES OF A CONSOLE THAT IS NOT THE ADVANCE, COMPARED IN A PROCESS WHERE THE ADVANCE'S
# EMULATOR CANNOT BE LOADED. A game for the Genesis or the Super Nintendo has its own console's
# emulator and has no use for ruby-gba-emulator, whose C extension a `path:` source in its Gemfile
# never builds. A comparison of its cartridges must play them without asking for that emulator.
#
# The process is a child of the test's, because this one has the Advance's emulator loaded (the
# test helper loads it up front). In the child, asking for ruby_gba_emulator raises the LoadError
# Ruby raises for a file that is not there: the bundle puts the gem's lib on the load path whatever
# is built, and the seam would find the checkout beside this one besides, so taking it off the load
# path is not enough.
#
# The two cartridges are a white box on a blue field that walks two pixels a frame while RIGHT is
# down, from column +from+, with a background +columns+ cells wide.
module ComparedWithoutAdvanceEmulator
  CHILD = <<~'RUBY'
    module RefuseAdvanceEmulator
      def require(name)
        raise LoadError, "cannot load such file -- #{name}" if name.to_s.start_with?("ruby_gba_emulator")

        super
      end
    end
    Kernel.prepend(RefuseAdvanceEmulator)

    require "vblank"
    require "stringio"

    console = ARGV.fetch(0).to_sym
    columns = Integer(ARGV.fetch(1))
    walker = lambda do |from|
      VBlank.build("WALKER", console: console, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        image(:box, "#" => :white) { "########\n" * 8 }
        image(:sea, "." => :blue) { "........\n" * 8 }
        tiles :set, "." => :sea
        background :field, tiles: :set, map: Array.new(32) { "." * columns }
        box = sprite :box, at: [from, 60]
        game_loop { box.x += 2 if held(:right) }
      end
    end
    walk = VBlank.playthrough("walk right") { hold :right, frames: 30 }
    alike = walk.compare(walker.call(20), walker.call(20))
    apart = walk.compare(walker.call(20), walker.call(28))
    print [alike.drift?, apart.drift?, apart.drift&.picture_difference&.dig(:box, 1),
           defined?(RubyGBAEmulator::Probe).inspect].inspect
  RUBY

  # Compares the two in the child for +console+, and asserts the two alike were found alike, the two
  # apart found apart at the box's row, and the Advance's emulator never loaded.
  # The child's script is a file, since a game is read from the file it is written in.
  private def assert_compared_without_advance_emulator(console, columns:)
    said, status = Dir.mktmpdir("compared-without-advance") do |dir|
      script = File.join(dir, "compare.rb")
      File.write(script, CHILD)
      Open3.capture2e(RbConfig.ruby, "-I", VBlank.root.join("lib").to_s, script, console.to_s, columns.to_s)
    end

    assert status.success?, said
    assert_equal [false, true, 60, "nil"].inspect, said.lines.last
  end
end
