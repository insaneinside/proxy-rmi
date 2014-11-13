require_relative('MethodInfo')
# Extracts interesting information about a class or module hierarchy.
# `ClassHierarchy` automates the extraction of API information from a class
# or module and all contained classes/modules/etc.
class ClassHierarchy
  @@instance_variable_dump_order = [ :@name, :@type,
                                    :@superclass,
                                    :@included_modules, :@constants,
                                    :@class_methods, :@class_variables,
                                    :@instance_methods, :@instance_variables,
                                    :@contained_modules, :@contained_classes,
                                   ]

  @name = nil
  @type = nil

  attr_reader :name
  attr_reader :type

  # Fetch the names of all classes contained within a given class or module.
  def self.contained_classes(m)
    m.constants.select { |c| m.const_get(c).kind_of?(::Class) }
  end

  # Fetch the names of all modules contained within a given class or module.
  # This method ignores instances of Class and any subclasses.
  def self.contained_modules(m)
    m.constants.select { |c| c = m.const_get(c)
      c.kind_of?(::Module) and not
      c.kind_of?(::Class) }
  end


  def inspect
    "#<#{self.class}:#{'%#x' % self.object_id.abs} %s %s>" % [@type.downcase, @name]
  end

  def to_s(depth=0)
    indent = '  ' * depth
    (indent + @type.downcase + ' ' + @name + (@superclass.nil? ? '' : ' < ' + @superclass) + "\n" +
      (@included_modules.nil? ? '' : @included_modules.collect { |imn| indent + '  include ' + imn }.join("\n") + "\n") +
      (@class_methods.nil? ? '' : @class_methods.values.collect { |m| indent + '  method self.' + m.to_s }.join("\n") + "\n") +
      (@instance_methods.nil? ? '' : @instance_methods.values.collect { |m| indent + '  method ' + m.to_s }.join("\n") + "\n") +
      (@contained_modules.nil? ? '' : @contained_modules.values.collect { |m| m.to_s(depth + 1) }.join("\n") + "\n") +
      (@contained_classes.nil? ? '' : @contained_classes.values.collect { |c| c.to_s(depth + 1) }.join("\n") + "\n")).
      gsub(/\n+/, "\n")
  end

  def [](name)
    name = name.kind_of?(Symbol) ? name : name.intern
    if name.to_s =~ /^[A-Z]/ # Constant
      if not @contained_modules.nil? and @contained_modules.has_key?(name)
        @contained_modules[name]
      elsif not @contained_classes.nil? and @contained_classes.has_key?(name)
        @contained_classes[name]
      elsif not @constants.nil? and @constants.has_key?(name)
        @constants[name]
      end
    elsif not @class_methods.nil? and @class_methods.has_key?(name)
      @class_methods[name]
    elsif not @instance_methods.nil? and @instance_methods.has_key?(name)
      @instance_methods[name]
    end
  end

  # def self.new_from_instance(root)
  #   o = self.allocate
  #   o.initialize_from_instance(root)
  #   o
  # end

  def initialize(root)
    # @full_name = root.name
    @name = root.name.split('::')[-1]
    @type = root.class.name
    raise TypeError.new('invalid inspection target') unless root.kind_of?(Module)
    _class_methods = root.methods - root.instance_methods#(false)
    _class_variables = root.class_variables
    _instance_methods = root.instance_methods(false)
    begin
      # as of Ruby 2.1.4, `initialize` isn't included in the list returned by
      # Module#instance_methods.
      _instance_methods << :initialize unless root.instance_method(:initialize).nil?
    rescue
    end
    _instance_variables = root.instance_variables

    _contained_classes = ClassHierarchy.contained_classes(root)
    _contained_modules = ClassHierarchy.contained_modules(root)
    _constants = root.constants - _contained_classes - _contained_modules
    _included_modules = root.included_modules

    # Remove inherited values

    # Ruby 1.8.6's `Method` objects don't respond to `owner`, so we have to
    # determine owner based on their `inspect` output.
    our_method_regexp = /^#<(?:Unbound)?Method: #{root.name}[#.]/
    _class_methods = _class_methods.select { |cm| our_method_regexp.match(root.method(cm).inspect) }

    root.ancestors[1..-1].each do |m|
      _class_variables -= m.class_variables
      _instance_variables -= m.instance_variables

      _contained_classes -= ClassHierarchy.contained_classes(m)
      _contained_modules -= ClassHierarchy.contained_modules(m)
      _included_modules -= m.included_modules
    end

    @superclass = root.superclass.name if root.class.name == 'Class' and root.superclass != ::Object
    @included_modules = _included_modules.collect { |im| im.name }.sort unless _included_modules.empty?
    @constants = _constants.sort.collect { |sym| [sym.kind_of?(Symbol) ? sym : sym.intern,
                                                  root.const_get(sym)] }.to_h unless _constants.empty?

    @class_methods = _class_methods.sort.collect { |sym| [sym.kind_of?(Symbol) ? sym : sym.intern,
                                                          MethodInfo.new(root.method(sym))] }.to_h unless _class_methods.empty?
    @instance_methods = _instance_methods.sort.
                          collect { |sym| [sym.kind_of?(Symbol) ? sym : sym.intern, MethodInfo.new(root.instance_method(sym))] }.
                          to_h unless _instance_methods.empty?
    @class_variables = _class_variables.sort.collect { |sym| sym.to_s } unless _class_variables.empty?
    @instance_variables = _instance_variables.collect { |sym| sym.to_s } unless _instance_variables.empty?

    @contained_classes = _contained_classes.
                           sort { |a, b| a <=> b }.
                           collect { |cc| [cc.kind_of?(Symbol) ? cc : cc.intern, ClassHierarchy.new(root.const_get(cc))] }.
                           to_h unless _contained_classes.empty?
    @contained_modules = _contained_modules.
                           sort { |a, b| a <=> b }.
                           collect { |cm| [cm.kind_of?(Symbol) ? cm : cm.intern, ClassHierarchy.new(root.const_get(cm))] }.
                           to_h unless _contained_modules.empty?
  end

  # Define accessor methods for the hierarchy object.  Note that doing so will interfere with dumping.
  def define_accessors(recursive = false)
    self.extend(ClassHierarchyAccessors)
    if recursive
      contained_classes.values.each { |v| v.define_accessors(recursive) } if respond_to?(:contained_classes)
      contained_modules.values.each { |v| v.define_accessors(recursive) } if respond_to?(:contained_modules)
    end
    nil
  end
end
module ClassHierarchyAccessors
  def instance_variables
    instance_variable_defined?(:@instance_variables) ? instance_variable_get(:@instance_variables) : []
  end
  def instance_methods
    instance_variable_defined?(:@instance_methods) ? instance_variable_get(:@instance_methods) : {}
  end

  def class_variables
    instance_variable_defined?(:@class_variables) ? instance_variable_get(:@class_variables) : []
  end
  def class_methods
    instance_variable_defined?(:@class_methods) ? instance_variable_get(:@class_methods) : {}
  end

  def superclass
    instance_variable_defined?(:@superclass) ? instance_variable_get(:@superclass) : nil
  end
  def contained_classes
    instance_variable_defined?(:@contained_classes) ? instance_variable_get(:@contained_classes) : {}
  end

  def contained_modules
    instance_variable_defined?(:@contained_modules) ? instance_variable_get(:@contained_modules) : {}
  end

  def included_modules
    instance_variable_defined?(:@included_modules) ? instance_variable_get(:@included_modules) : []
  end

  def constants
    instance_variable_defined?(:@constants) ? instance_variable_get(:@constants) : {}
  end
end
