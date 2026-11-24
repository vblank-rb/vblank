# frozen_string_literal: true

module VBlank
  module Diagnostics
    # The fast Fourier transform, the radix-2 one of Cooley and Tukey: a list of numbers a power of two
    # long as the frequencies it holds, the real and the imaginary part of each. Done in place over the
    # numbers put in +order+ (FastFourier.order: each place's number with its bits reversed).
    #
    # +imaginary+ is the imaginary part of the numbers given, nought where left out. +inverse+ turns
    # frequencies back into the numbers they came from, divided by the size, so a transform and its
    # inverse give back what went in.
    module FastFourier
      def self.transform(real, order, imaginary = nil, inverse: false)
        size = real.size
        real = order.map { |at| real[at].to_f }
        imaginary = imaginary ? order.map { |at| imaginary[at].to_f } : Array.new(size, 0.0)
        turn_sign = inverse ? 2 : -2
        span = 2
        while span <= size
          half = span / 2
          step = turn_sign * Math::PI / span
          (0...half).each do |turn|
            cos = Math.cos(step * turn)
            sin = Math.sin(step * turn)
            (turn...size).step(span) do |at|
              other = at + half
              re = (real[other] * cos) - (imaginary[other] * sin)
              im = (real[other] * sin) + (imaginary[other] * cos)
              real[other] = real[at] - re
              imaginary[other] = imaginary[at] - im
              real[at] += re
              imaginary[at] += im
            end
          end
          span *= 2
        end
        return [real, imaginary] unless inverse

        [real.map { |value| value / size }, imaginary.map { |value| value / size }]
      end

      # The places 0 to +size+ - 1, each with its bits reversed: the order the transform reads its
      # numbers in.
      def self.order(size)
        bits = Math.log2(size).to_i
        Array.new(size) { |at| at.to_s(2).rjust(bits, "0").reverse.to_i(2) }
      end
    end
  end
end
