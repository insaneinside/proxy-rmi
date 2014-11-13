# -*- coding: utf-8 -*-
require_relative '../helpers'

module TestProxy
  include Minitest::Assertions
  class TestMessage < Minitest::Test
    PMT = Proxy::Message::Type
    PM = Proxy::Message

    # Basic tests for type safety in the Message::Type message-type
    # symbol-mapping utility.
    class TestType < Minitest::Test
      def test_class_intern
        assert_raises(TypeError) { PMT.intern(:foo) }
        PMT.constants(false).each do |c|
          assert_equal(c.to_s.downcase.intern, PMT.intern(PMT.const_get(c)))
        end
      end

      def test_class_extern
        assert_raises(TypeError) { PMT.extern(32) }
        PMT.constants(false).each do |c|
          assert_equal(PMT.const_get(c), PMT.extern(c.to_s.downcase.intern))
        end
      end
    end

    TEST_DATA = [ [Proxy::GenericMessage.new(:bye, seq: 3), :bye, 3],
                  [PM.invoke(12345, :foo, [:a, 1, 2, 3], nil, 9), :invoke, 9] ]

    def setup
      @msg = TEST_DATA[rand(TEST_DATA.size)][0]
    end
    def msg
      @msg
    end

    def test_invocation?
      assert_equal(true, PM.invoke(12345, :foo, [], nil).invocation?)
      assert_equal(false, PM.export({a: :b, 'r' => 2, d: 2}).invocation?)
    end

    def test_methods
      klasses = ObjectSpace.each_object(Class).select { |el| el.ancestors.include?(Proxy::Message) }
      refute klasses.empty?, 'Proxy::Message must have subclasses'
      klasses.each do |klass|
        assert_equal(klass, klass.instance_method(:==).owner)
      end
    end

    def test_type
      assert_equal(true, msg.instance_variable_defined?(:@type))
      assert_kind_of(Symbol, msg.type)
      ivval = msg.instance_variable_get(:@type)

      refute_equal(ivval, msg.type)
      assert_kind_of(Integer, ivval)
    end
    TEST_DATA.each_index do |i|
      define_method(('test_message_%d' % i).intern) do
        msg, expected_type, expected_seq = TEST_DATA[i]

        refute_nil(msg.type)
        assert_equal(PMT.extern(msg.type), msg.instance_variable_get(:@type))
        assert_equal(expected_type, msg.type)
        assert_equal(expected_seq, msg.instance_variable_get(:@seq))
        assert_equal(expected_seq, msg.seq)
        mddata = msg.marshal_dump
        assert_kind_of(Integer, mddata[0])

        new_msg = msg.class.allocate
        new_msg.marshal_load(msg.marshal_dump)
        assert_equal(msg, new_msg)
      end
    end
  end
end
