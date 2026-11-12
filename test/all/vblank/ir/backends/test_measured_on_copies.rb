# frozen_string_literal: true

require "test_helper"

# EVERY LOWERING THAT CUTS ROUTINES MEASURES A RUN OF STATEMENTS THE SHARED WAY OR IS LISTED WITH ITS REASON: it
# takes MeasuredOnCopies#bytes_of, or it is in MeasuredOnCopies::OWN_WAYS with its reason, never
# both. A lowering cuts routines when it keeps a LOWERING_STATE (RoutineCuts.for).
class TestMeasuredOnCopies < Minitest::Test
  Backends = VBlank::IR::Backends
  LOWERINGS = { "GBC" => Backends::GBC::Lowering, "SNES" => Backends::SNES::Lowering,
                "Genesis" => Backends::Genesis::Lowering, "PS1" => Backends::PS1::Lowering }.freeze

  def test_each_lowering_that_cuts_routines_measures_the_shared_way_or_is_listed
    LOWERINGS.each do |name, lowering|
      next unless lowering.const_defined?(:LOWERING_STATE, false)

      shared = lowering.include?(Backends::MeasuredOnCopies)
      listed = Backends::MeasuredOnCopies::OWN_WAYS.key?(name)

      assert shared ^ listed, "#{name}: takes MeasuredOnCopies or is listed in its OWN_WAYS, and not both"
    end
  end

  def test_every_lowering_listed_cuts_routines
    Backends::MeasuredOnCopies::OWN_WAYS.each_key do |name|
      assert LOWERINGS.fetch(name).const_defined?(:LOWERING_STATE, false), "#{name} is listed and cuts no routines"
    end
  end
end
