# frozen_string_literal: true

# What a test that starts Ractor workers by hand needs: quiet about Ractors being experimental, and
# the error a worker stopped with raised as it was.
module RactorWorkers
  # What +ractor+ ended with, or the error it stopped with raised as it was, so a failure names the
  # line that stopped rather than the test's.
  private def value_raising_its_cause(ractor)
    ractor.value
  rescue Ractor::RemoteError => e
    raise e.cause, cause: nil
  end

  # Run the block with +owner+'s singleton method +method+ answered by +stand_in+, a shareable proc,
  # and put the real method back after. For a test on the main Ractor while the workers play other
  # files beside it, which may call the same method at any moment.
  #
  # ### Why it is swapped through aliases
  #
  # Ruby lets a method made from a plain block, or defined again from another method's handle, be
  # called only on the Ractor that made it, so the stand-in is a shareable proc and the real method
  # is put back by name. Each swap is one alias over the method, never a removal first, so a worker
  # calling at that moment finds one method or the other and never none. The stand-in keeps a name
  # of its own until the real method is back, so nothing is discarded while Ruby's warnings are on.
  private def while_swapped(owner, method, stand_in)
    real = :"__real_#{method}"
    standing_in = :"__stand_in_#{method}"
    owner.singleton_class.alias_method(real, method)
    owner.define_singleton_method(standing_in, &stand_in)
    owner.singleton_class.alias_method(method, standing_in)
    yield
  ensure
    owner.singleton_class.alias_method(method, real)
    owner.singleton_class.remove_method(standing_in)
    owner.singleton_class.remove_method(real)
  end

  # Ractors announce that they are experimental every time one is made. The library does not choose
  # that and a test run should not carry it.
  private def without_the_experimental_warning
    was = Warning[:experimental]
    Warning[:experimental] = false
    yield
  ensure
    Warning[:experimental] = was
  end
end
