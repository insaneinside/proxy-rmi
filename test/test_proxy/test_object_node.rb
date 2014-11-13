require_relative '../helpers'
require 'fileutils'
require 'socket'

module TestProxy
  include Minitest::Assertions
  class TestObjectNode < Minitest::Test
    PM = Proxy::Message

    def setup
      socks = UNIXSocket.socketpair
      @a = Proxy::ObjectNode.new(socks[0])
      @b = Proxy::ObjectNode.new(socks[1])
    end
    def teardown
      @a.close
      @b.close
    end

    def test_handle_message()
      msg = ::TestProxy.random_message()
      if msg.type == :error
        assert_raises(msg.exception.class) { @a.handle_message(msg) }
      elsif msg.type == :literal
        assert_equal(false, @a.handle_message.kind_of?(Proxy::Object))
      end
    end
  end
end
