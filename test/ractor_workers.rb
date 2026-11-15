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
