require_relative 'helpers'

module TestProxy
  class TestProxy < Minitest::Test
    include Minitest::Assertions


    # Check that Proxy.require bypases Gem's stacktrace-obfuscating stupidity.
    def test_class_require
      begin
        Proxy.require('this-can-not-possibly-exist')
      rescue LoadError => err
        assert_equal([], err.backtrace.select { |el| el =~ /gem_original_require/ })
      end
    end

    def test_class_require_relative
      # raise NotImplementedError, 'Need to write test_class_require_relative'
    end
  end
end

