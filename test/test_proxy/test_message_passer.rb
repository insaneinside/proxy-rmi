require_relative '../helpers'
require 'fileutils'
require 'socket'

module TestProxy
  include Minitest::Assertions
  class TestMessagePasser < Minitest::Test
    PM = Proxy::Message
    def setup
      @socks = UNIXSocket.socketpair
      @a = Proxy::MessagePasser.new(@socks[0])
      @b = Proxy::MessagePasser.new(@socks[1])
    end
    def teardown
      @a.close
      @b.close
    end

    def test_socket
      assert_equal(@socks[0], @a.socket)
      assert_equal(@socks[1], @b.socket)
    end

    def test_close()
      @a.close()
      assert_equal(true, @a.stopping?)
      assert_equal(false, @a.connection_open?)
    end

    def test_stopping()
      assert_equal(false, @a.stopping?)
      assert_equal(false, @b.stopping?)
      @a.close
      assert_equal(true, @a.stopping?)
      assert_equal(false, @b.stopping?)
    end

    def test_connection_open?
      assert_equal(true, @a.connection_open?)
      @a.close
      assert_equal(false, @a.connection_open?)
      # B won't notice that the connection has dropped until it tries to write
      # to it (we handle graceful connection shutdown at the protocol level, in
      # ObjectNode).
      assert_equal(true, @b.connection_open?)
    end

    # There's not much of a way to test MessagePasser#stopping, since it simply
    # reflects a flag used to stop #send_message from trying to send messages
    # after #close has been called.
    def test_stopping?
      @a.respond_to?(:stopping?)
      @a.close
      assert_equal(true, @a.stopping?)
      assert_equal(false, @a.connection_open?)
    end

    # Well, we did this in `setup`...
    def test_initialize
      test_socket
      assert_equal(true, @a.connection_open?)
      assert_equal(false, @a.stopping?)

      assert_equal(true, @b.connection_open?)
      assert_equal(false, @b.stopping?)
    end

    def test_wait_for_message()
      $q = nil
      thr = Thread.new { $q = @b.wait_for_message(:insert_seq_here) }
      def @b.handle_message(m)
      end
      @a.send_message(::TestProxy.random_message(), 42)
      @a.send_message(Proxy::GenericMessage.new(:bye, seq: 32))
      assert_equal(nil, $q)
      @a.send_message(Proxy::GenericMessage.new(:literal, value: 3, seq: :insert_seq_here))
      thr.join()
      assert_equal(:literal, $q.type)
      assert_equal(3, $q.value)
    end



    def test_send_message
      m = ::TestProxy.random_message()
      @a.send_message(m)
      assert_equal(m, @b.receive_message)
    end
    alias :test_receive_message :test_send_message
  end
end
