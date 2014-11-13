require_relative '../helpers'

module TestProxy
  class TestAttributes < Minitest::Test
    include Minitest::Assertions

    CLASS_ATTRS = [:nocopy, :foo, :bar, :baz]


    def setup
      classes = ObjectSpace.each_object(Class).to_a
      @class = classes[rand(classes.size)]
    end
    
    def test_class_find_class_by_name
      assert_equal(@class, Proxy.find_class_by_name(@class.name))
    end

    def test_class_get_class_attributes
      # attribute fetching must be repeatable
      prev_attrs = Proxy.get_class_attributes(@class)
      assert_kind_of(Array, prev_attrs)
      assert_equal(prev_attrs, Proxy.get_class_attributes(@class))
      assert_equal(Proxy.get_class_attributes(ProxyHelpers::A, -1), Proxy.get_class_attributes(ProxyHelpers::A, true))
    end


    def test_class_set_class_attributes
      # Must be able to set new attributes.
      assert_nothing_raised { Proxy.set_class_attributes(@class, []) }
      assert_nothing_raised { assert_equal([], Proxy.get_class_attributes(@class, false)) }

      assert_nothing_raised { Proxy.set_class_attributes(@class, CLASS_ATTRS) }
      assert_equal(CLASS_ATTRS, Proxy.get_class_attributes(@class, false))


      # Class attributes should cascade.
      Proxy.set_class_attributes(ProxyHelpers::A, [:attribute_a])
      Proxy.set_class_attributes(ProxyHelpers::B, [:attribute_b])
      assert_equal([:attribute_b], Proxy.get_class_attributes(ProxyHelpers::B, false))
      assert_equal([:attribute_b, :attribute_a] | Proxy.get_inherited_class_attributes(ProxyHelpers::A),
                   Proxy.get_class_attributes(ProxyHelpers::B))

      assert_equal(Proxy.get_class_attributes(ProxyHelpers::A, false), [:attribute_a])
      assert_equal(Proxy.get_class_attributes(ProxyHelpers::A, 0), [:attribute_a])
    end

    def test_class_get_inherited_class_attributes
      klass = ProxyHelpers::B
      while not klass.nil?
        break if klass.ancestors[1] == klass
        assert_equal(Proxy.get_inherited_class_attributes(klass), Proxy.get_class_attributes(klass.ancestors[1], true))
        klass = klass.ancestors[1]
      end
    end


    def test_class_remove_inherited_class_attributes
      Proxy.set_class_attributes(ProxyHelpers::A, [:attribute_a])
      Proxy.remove_inherited_class_attributes(ProxyHelpers::B, [:attribute_a])
      refute_includes([:attribute_a], Proxy.get_inherited_class_attributes(ProxyHelpers::B))
    end

    def test_class_get_method_attributes
      assert_kind_of(Hash, Proxy.get_method_attributes(@class))
      assert_kind_of(Array, Proxy.get_method_attributes(@class, :this_method_probably_does_not_exist))

    end

    def test_class_set_method_attributes
      # raise NotImplementedError, 'Need to write test_class_set_method_attributes'
    end
  end
end

