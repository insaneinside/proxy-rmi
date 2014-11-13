# Helpers for ProxyRMI unit tests
require 'minitest/autorun'


module Minitest::Assertions
  def assert_nothing_raised(msg = nil, &block)
    raised = false
    begin
      block.call()
    rescue => err
      msg = message(msg) { "<#{mu_pp(err)}> was thrown when nothing was expected" }
      raised = true
    end
    assert raised == false, msg
  end
end


module ProxyHelpers
  class A
    def doesnt_return
      Kernel.exit(0)
    end
  end

  class B < A
    def dont_copy_copyable_result
      (1..10).to_a
    end
    def self.another_nocopy_method
      42
    end
  end
end

require 'coverage.so'
require 'simplecov'
SimpleCov.start do
  # add_filter '/test/'
  root File.expand_path('../..', __FILE__)
end

require_relative '../lib/proxy.rb'
require_relative 'messages'
Proxy.set_method_attributes(ProxyHelpers::A, :doesnt_return, :instance, [:noreturn])
Proxy.set_method_attributes(ProxyHelpers::B, :dont_copy_copyable_result, :instance, [:nocopy])
Proxy.set_method_attributes(ProxyHelpers::B, :another_nocopy_method, :class, [:nocopy])
