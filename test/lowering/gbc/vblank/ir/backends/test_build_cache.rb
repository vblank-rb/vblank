# frozen_string_literal: true

require "test_helper"

# What a cartridge build works out from its program once, for all its tries (BuildCache). Shared by
# the cartridge lowerings and playing no game, so its tests are with the Color's.
class TestBuildCache < Minitest::Test
  include VBlank::IR::Build

  Backends = VBlank::IR::Backends
  GBC = Backends::GBC

  private def game
    made = program(bitmap(:dot, width: 8, height: 8, pixels: Array.new(64, 0x001F), transparent: nil),
                   func(:score, add(:points, 1)), call(:score), loop_(wait_vblank))
    made.console = :gbc
    made
  end

  def test_every_try_of_a_build_reads_one_plan_and_one_handover
    cache = Backends::BuildCache.for(GBC, game)
    first = GBC::Lowering.new(cache.program, memory: GBC::Memory.new, cache: cache)
    second = GBC::Lowering.new(cache.program, memory: GBC::Memory.new, cache: cache, tile_rooms: true)

    assert_same first.instance_variable_get(:@plan), second.instance_variable_get(:@plan)
    assert_same cache.plan.handover, cache.handover
  end

  def test_a_picture_is_read_once_by_its_node
    cache = Backends::BuildCache.for(GBC, game)
    node = cache.program.walk.find { |each| each.kind == :bitmap }

    assert_same cache.image(node), cache.image(node)
    assert_equal VBlank::IR::Assets::Image.of(node), cache.image(node)
  end

  def test_two_builds_have_two_caches
    refute_same Backends::BuildCache.for(GBC, game).plan, Backends::BuildCache.for(GBC, game).plan
  end

  def test_the_plan_refuses_in_the_lowerings_own_error
    cache = Backends::BuildCache.for(GBC, game)

    assert_equal GBC::LoweringError, cache.plan.instance_variable_get(:@error)
  end
end
