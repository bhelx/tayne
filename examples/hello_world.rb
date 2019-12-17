# typed: true
require 'sorbet-runtime'

module Main
  extend T::Sig

  sig {returns(Integer)}
  def main
    msg = "Hello World!!"
    puts msg
    0
  end
end
