# @file
#
#  Defines module methods on Proxy for storing and fetching class- or
#  class/method-specific attributes used by the library to determine how to (or
#  how *not* to) invoke methods and proxy remote objects.
#
# Because it would be nice to eventually have a way to share locally-declared
# attributes with a node's partner to enable e.g. skipping reply messages for
# methods marked :noreturn, we'll avoid keying attributes by the methods or
# classes themselves.  This *does* force us to look up method attributes by
# class-symbol pair, but gives us more options for future development.
module Proxy
  @@method_attributes_table = Hash.new(Hash.new([]))
  @@class_attributes_table = Hash.new([])
  @@negated_class_attributes_table = Hash.new([])

  # Set the list of attributes for a specific class.
  #
  # @param [Class] klass Class object reference for which attributes are to
  #     be set.
  #
  # @param [Array<Symbol>] attrs Attributes for the class.  Note that this
  #   list will *replace* any previously-set attributes.
  def self.set_class_attributes(klass, attrs)
    klass = klass.to_s if klass.kind_of?(Module)
    @@class_attributes_table[klass] = attrs
  end

  # Set a list of attributes that should not be inherited from
  # a class's ancestors.
  # 
  # @param [Class] klass Class object reference for which attributes are to
  #     be cleared.
  # 
  # @param [Array<Symbol>] attrs Attributes to remove.  Note that this list
  #   will *replace* any previously-set cleared-attributes list.
  def self.remove_inherited_class_attributes(klass, attrs)
    klass = klass.to_s if klass.kind_of?(Module)    
    @@negated_class_attributes_table[klass] = attrs
  end

  # Fetch the list of attributes for a class.  The returned list combines the
  # attributes for `klass` and all ancestors.
  #
  # @param [Class,String] klass Class or class-name for which to look
  #   up attributes.
  #
  # @param [Boolean] include_ancestors If `true`, include attributes set on the
  #   class's ancestors.
  # 
  # @return [Array<Symbol>]
  def self.get_class_attributes(klass, include_ancestors = false)
    if klass.nil?
      []
    else
      klass_name = (klass.kind_of?(Module) ? klass.name : klass).to_s
      o = @@class_attributes_table[klass_name]
      if include_ancestors and klass.kind_of?(Module)
        # klass = Proxy.find_class_by_name(klass) if klass.kind_of?(String)
        o = o | (self.get_inherited_class_attributes(klass, include_ancestors) - @@negated_class_attributes_table[klass_name])
      end
      o
    end
  end

  # Get all *inherited* attributes for a class.
  def self.get_inherited_class_attributes(klass, depth = nil)
    depth ||= klass.ancestors.length
    self.get_class_attributes(klass.ancestors[1], depth)
  end



  # Set the list of attributes for a specific (instance!) method.
  #
  # @param [Class] klass Class on which the specified method has the given
  #     attributes.
  #
  # @param [Symbol] method Name (as a Symbol) of the method to apply
  #     attributes to.
  #
  # @param [:instance,:class] type Kind of method for which attributes are
  #     being set.

  # @param [Array<Symbol>] attrs Attributes for the method.  Note that this
  #   list will *replace* any previously-set attributes.
  def self.set_method_attributes(klass, method, type, attrs)
    klass_name = (klass.kind_of?(Module) ? klass.name : klass).to_s

    # Check ownership if we have more than just a name for the class.
    if klass.kind_of?(Module)
      m = case type
          when :class
            klass.method(method)
          when :instance
            klass.instance_method(method)
          end
      raise NoMethodError.new('Method `%s` on `%s` is owned by `%s`' %
                              [method.to_s, klass.name, m.owner.name]) \
        unless m.owner.inspect =~ /#{Regexp.escape(klass.name)}/
    end

    @@method_attributes_table[klass_name][method] = attrs
  end
  public_class_method :set_method_attributes

  # Fetch the list of attributes for a specific method, or a hash containing
  # attributes for each method in a class on which they have been set.
  #
  # @param [Class] klass Class on which method attributes are to be retrieved.
  #
  # @param [Symbol] method Name (as a Symbol) of the method for which
  #     attributes should be retrieved.
  #
  # @param [Array<Symbol>] attrs Attributes for the method.  Note that this
  #   list will *replace* any previously-set attributes.
  def self.get_method_attributes(klass, method = nil)
    klass = klass.name.to_s if klass.kind_of?(Module)
    r = @@method_attributes_table[klass]
    r = r[method] unless method.nil?
    r
  end

  set_class_attributes(::Exception, [:nocopy])
  set_class_attributes(::Proc, [:nocopy])
end
