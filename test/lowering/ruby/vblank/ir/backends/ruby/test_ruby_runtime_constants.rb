# frozen_string_literal: true

require "test_helper"
require "prism"

# Every constant the Ruby runtime sets can be shared between Ractors. A port's shell plays its
# unpacking inside a Ractor (Live::BackgroundUnpacking), and Ruby refuses to set a constant there
# that holds a mutable object, so one table frozen only on the outside stops a shell's first start.
# Each constant's value is worked out here on its own, in file order, as the runtime sets it; one
# that needs a method of the running game to work out is left to the runs that play it.
class TestRubyRuntimeConstants < Minitest::Test
  RUNTIME_FOLDERS = [VBlank.root.join("lib/vblank/ir/backends/ruby/runtime"),
                     VBlank.root.join("lib/vblank/ir/backends/runtime_features")].freeze

  def test_every_runtime_constant_is_shareable
    unshared = runtime_constants.reject { |_where, value| Ractor.shareable?(value) }

    assert_empty unshared.map(&:first), "these runtime constants hold a mutable object a Ractor cannot set"
  end

  private

  # [where, value] for each constant the runtime sets at its files' top level.
  def runtime_constants
    sandbox = Module.new
    runtime_files.flat_map do |path|
      top_level_constants(path).filter_map do |node|
        value = sandbox.module_eval(node.slice, path.to_s, node.location.start_line)
        ["#{path.basename}:#{node.location.start_line} #{node.name}", value]
      rescue NameError, NoMethodError, ArgumentError, TypeError
        nil
      end
    end
  end

  def runtime_files
    RUNTIME_FOLDERS.flat_map { |folder| Dir.glob(folder.join("**/*.rb")).sort }
                   .reject { |path| File.basename(path) == "feature.rb" }
                   .map { |path| Pathname(path) }
  end

  def top_level_constants(path)
    Prism.parse_file(path.to_s).value.statements.body.grep(Prism::ConstantWriteNode)
  end
end
