# Parses source and test trees to determine unit-test coverage.

require 'pp'
require 'find'
require 'ruby_parser'
require 'sexp_processor'

LIB_DIR = File.expand_path('../../lib', __FILE__)
TESTS_DIR = File.expand_path('../', __FILE__)
IGNORE_FILES = [ __FILE__ ]

# Find (recursively) all Ruby source files within a given directory and place
# their paths into the given array.
#
# @param [String] root Root directory path.
# @param [Array] dest Array in which to store paths to found Ruby source files.
def find_files(root, dest = [])
  append = []
  Find.find(root) do |path|
    if path[0] == '.'
      Find.prune
      next
    elsif not File.directory?(path) and
        path =~ /\.rb\Z/ and not IGNORE_FILES.include?(path)
      append << path
    end
  end 
 append.sort!
  append.uniq!
  dest += append
  dest
end

source_files = find_files(LIB_DIR)
test_files = find_files(TESTS_DIR)


# A scope (i.e., class or module) definition from one or more parsed file(s).
class Scope
  @parent = nil
  @type = nil
  @name = nil
  @included_modules = nil
  @instance_methods = nil
  @class_methods = nil
  @subscopes = nil
  
  attr_reader :parent
  attr_reader :type
  attr_reader :name

  def module?; @type == :module; end
  def class?; @type == :class; end

  def included_modules
    instance_variable_defined?(:@included_modules) \
      ? @included_modules.clone \
      : [].freeze
  end

  def include_module(mod)
    if mod.kind_of?(Sexp)
      raise mod.inspect
    end
    @included_modules = [] unless instance_variable_defined?(:@included_modules)
    @included_modules << mod
  end

  def subscope(name)
    name = name.intern
    subscopes(:module)[name] || subscopes(:class)[name]
  end

  def all_subscopes(recursive = false)
    o = subscopes(:module).values + subscopes(:class).values
    if recursive
      subscopes(:module).values.each { |ssc| o += ssc.all_subscopes(recursive) }
      subscopes(:class).values.each { |ssc| o += ssc.all_subscopes(recursive) }
    end
    o
  end

  def subscopes(kind, recursive = false)
    if instance_variable_defined?(:@subscopes)
      o = @subscopes[kind].clone
      if recursive
        o = o.values
        @subscopes[kind].values.each { |ssc| o += ssc.subscopes(kind, true) }
      end
      o
    else
      recursive ? [].freeze : {}.freeze
    end
  end

  def full_name(anchor = false)
    (@parent.nil? or (@parent.type == :global and not anchor))\
      ? @name \
      : [@parent.full_name, @name].join('::')
  end

  def instance_methods
    @instance_methods = [] unless instance_variable_defined?(:@instance_methods)
    @instance_methods
  end

  def class_methods
    @class_methods = [] unless instance_variable_defined?(:@class_methods)
    @class_methods
  end

  def has_subscope?(name)
    has_module?(name) or has_class?(name)
  end

  def has_class?(name)
    contained_classes.has_key?(name.intern)
  end
  def has_module?(name)
    contained_modules.has_key?(name.intern)
  end

  def contained_classes
    if instance_variable_defined?(:@subscopes)
      @subscopes[:class].clone
    else
      {}.freeze
    end
  end
  def contained_modules
    if instance_variable_defined?(:@subscopes)
      @subscopes[:module].clone
    else
      {}.freeze
    end
  end

  attr_accessor :superclass

  def initialize(*a)
    case a.length
    when 1
      @type = a.first
    when 2
      @type, @name = a
    when 3
      @parent, @type, @name = a
    end
  end

  def to_s(depth=0)
    indent = '  ' * depth
    ((@type != :global ? (indent + @type.to_s + ' ' + @name.to_s + (@superclass.nil? ? '' : ' < ' + @superclass) + "\n") : '') +
      (@included_modules.nil? ? '' : @included_modules.sort.collect { |imn| indent + '  include ' + imn.to_s }.join("\n") + "\n") +
      (@class_methods.nil? ? '' : @class_methods.sort.collect { |m| indent + '  method ' + m.to_s }.join("\n") + "\n") +
      (@instance_methods.nil? ? '' : @instance_methods.collect { |m| indent + '  method ' + m.to_s }.join("\n") + "\n") +
      (contained_modules.empty? ? '' : contained_modules.values.sort.collect { |m| m.to_s(depth + 1) }.join("\n") + "\n") +
      (contained_classes.empty? ? '' : contained_classes.values.sort.collect { |c| c.to_s(depth + 1) }.join("\n") + "\n")).
      gsub(/\n+/, "\n")
  end

  def inspect
    "#<#{self.class}:#{'%#x' % self.object_id.abs}:%s%s>" % [@type.to_s, @name.nil? ? '' : ' ' + full_name.to_s]
  end


  def <<(scope)
    @subscopes = Hash.new { |hsh,k| hsh[k] = {} } unless instance_variable_defined?(:@subscopes)
    case scope.type
    when :module
      @subscopes[:module][scope.name.intern] = scope
    when :class
      @subscopes[:class][scope.name.intern] = scope
    else
      raise TypeError.new('Invalid scope type: %s' % scope.type)
    end
  end

  # Find a sub-scope object by type and name.  Use of this method is preferred
  # over the `subscopes` attribute because it checks for conflicting
  # scope types.
  #
  # @param [:class, :module] _type Kind of scope to look for.
  # @param [Symbol] _name Name of the scope to look for.
  def find_scope(_type, _name)
    if not instance_variable_defined?(:@subscopes)
      nil
    else
      o = @subscopes[_type][_name]

      # Check if someone previously defined this scope name as the *other* type.
      if o.nil?
        a = [:module,:class]
        a.delete(_type)
        if @subscopes[a.first].has_key?(_name)
          raise TypeError.new('Type mismatch: %s was previously defined as a %s' %
                              [_name, a.first])
        end
      end
      o
    end
  end

  def <=>(other)
    self.full_name <=> other.full_name
  end
end

# SexpProcessor implementation to extract data we need from
# a `ruby_parser` AST.
class Extractor < SexpProcessor
  @scopes = nil
  @method_depth = nil

  def initialize(global_scope = nil)
    @scopes = []
    @method_depth = 0
    @depth = 0
    @scopes.push(global_scope.nil? ? Scope.new(:global) : global_scope)
    super()
  end

  def process(sexp)
    @depth += 1
    super
    @depth -= 1
  end

  def process(sexp)
    sexp.kind_of?(Sexp) \
      ? (sexp.empty? ? nil : super(sexp)) \
      : sexp
  end

  def push_scope(type, name)
    name = process(name).first if name.kind_of?(Sexp)
    if not (q = @scopes[-1].find_scope(type, name)).nil?
      @scopes.push(q)
    else
      q = Scope.new(@scopes[-1], type, name)
      @scopes[-1] << q
      @scopes.push(q)
    end
  end

  def process_const(exp)
    exp.shift
    return s(exp.shift)
  end

  def process_colon2(exp)
    exp.shift
    s([process(exp.shift),process(exp.shift)].join('::').intern)
  end

  def process_alias(exp)
    exp.shift
    @scopes[-1].instance_methods << process(exp.shift)[1]
    exp.clear
    exp
  end

  def process_defn(exp)
    @method_depth += 1
    exp.shift
    @scopes[-1].instance_methods << exp.shift
    exp.clear
    @method_depth -= 1
    exp
  end

  def process_defs(exp)
    @method_depth += 1
    exp.shift
    @scopes[-1].class_methods << exp.shift(2).collect { |se| process(se) }.join('.')
    exp.clear
    @method_depth -= 1
    exp
  end    

  def process_call(exp)
    if @method_depth == 0
      exp.shift
      if exp.shift(2) == [nil, :include]
        @scopes[-1].include_module(process(exp.shift).first)
        exp.clear
      end
    end
    exp.clear
    exp
  end

  def process_module(exp)
    push_scope(*exp.shift(2))
    exp.each { |s| process(s) }
    exp.clear
    @scopes.pop()
    exp
  end
  alias :process_class :process_module
end

def parse_files(files, dest_scope = nil)
  dest_scope = Scope.new(:global) if dest_scope.nil?
  files.each do |file|
    q = RubyParser.new.parse(File.read(file), file)
    Extractor.new(dest_scope).process(q)
  end
  dest_scope
end

class CoverageData
  attr_reader :scope
  attr_reader :untested_scopes
  attr_reader :untested_methods
  attr_reader :subtree
  attr_reader :class_method_count
  attr_reader :instance_method_count
  attr_reader :untested_methods

  def initialize(a = nil, b = nil)
    if a.nil? and b.nil?
      @class_method_count = 0
      @instance_method_count = 0
      @untested_methods = []
    else
      @class_method_count = a.class_method_count + b.class_method_count
      @instance_method_count = a.instance_method_count + b.instance_method_count
      @class_methods_covered = a.class_methods_covered + b.class_methods_covered
      @instance_methods_covered = a.instance_methods_covered + b.instance_methods_covered
      um = (a.untested_methods||[]) + (b.untested_methods||[])
      @untested_methods = um unless um.empty?

      if a.instance_variable_defined?(:@untested_scopes) or b.instance_variable_defined?(:@untested_scopes)
        @untested_scopes = []
        @untested_scopes += a.untested_scopes if a.instance_variable_defined?(:@untested_scopes)
        @untested_scopes += b.untested_scopes if b.instance_variable_defined?(:@untested_scopes)
      end
    end
  end

  def combine
    if instance_variable_defined?(:@subtree)
      o = CoverageData.new(self, CoverageData.new())
      @subtree.each { |el| o += el.combine }
      o
    else
      self
    end
  end

  def instance_methods_covered
    instance_variable_defined?(:@instance_methods_covered) \
      ? @instance_methods_covered \
      : []
  end      
  def instance_methods_covered=(n)
    @instance_methods_covered = n
  end

  def class_methods_covered
    instance_variable_defined?(:@class_methods_covered) \
      ? @class_methods_covered \
      : []
  end      
  def class_methods_covered=(n)
    @class_methods_covered = n
  end

  def self.generate(a, b = nil)
    recurse_reduction = :none
    recurse = false
    if not b.nil?
      if b.kind_of?(Symbol)
        recurse_reduction = b
        recurse = true
      elsif b.kind_of?(TrueClass)
        recurse = true
      end
    else
      recurse = false
    end
    o = CoverageData.new
    o.instance_variable_set(:@scope, a.source_scope)
    o.instance_variable_set(:@class_method_count, a.source_scope.class_methods.length)
    o.instance_variable_set(:@instance_method_count, a.source_scope.instance_methods.length)
    o.instance_methods_covered = a.source_scope.instance_methods.select { |sym|
      target = /\Atest_#{Regexp.escape(sym)}/
      a.test_scope.instance_methods.select { |tsym| tsym =~ target }.any? } \
      unless a.source_scope.instance_methods.empty? or a.test_scope.nil?
    o.untested_methods.concat(a.source_scope.instance_methods - o.instance_methods_covered)

    o.class_methods_covered = a.source_scope.class_methods.select { |sym|
      a.test_scope.class_methods.select { |tsym| tsym =~ /\Atest_#{Regexp.escape(sym)}/ }.any? } \
      unless a.source_scope.class_methods.empty? or a.test_scope.nil?
    o.untested_methods.concat(a.source_scope.class_methods - o.class_methods_covered)

    if recurse and a.has_subtree?
      case recurse_reduction
      when :combine
        a.subtree.each { |sth| o += self.generate(sth, recurse_reduction) }
      when :none
        o.instance_variable_set(:@subtree, [])
        a.subtree.each { |sth| o.subtree << self.generate(sth, recurse_reduction) }
      end
    end
    o
  end
  def +(other)
    CoverageData.new(self, other)
  end
end


# Container used to pair source scopes with their test-scope counterparts.
class ScopeTestingHierarchy
  @source_scope = nil
  @test_scope = nil
  @subtree = nil

  attr_reader :source_scope
  attr_reader :test_scope
  attr_reader :subtree

  def has_subtree?
    instance_variable_defined?(:@subtree)
  end

  def coverage(recursive = true)
    CoverageData.generate(self, recursive)
  end

  def initialize(_source_scope, _test_scope)
    @source_scope = _source_scope
    if ! _test_scope.nil? and ! _test_scope.class?
      @test_scope = _test_scope.find_scope(:class, 'Test' + @source_scope.name.to_s)
    else
      @test_scope = _test_scope
    end

    @subtree = ScopeTestingHierarchy.build_subtree(_source_scope, _test_scope) unless
      _test_scope.nil? or _source_scope.all_subscopes.empty?
  end

  # Check if a particular scope is present within this testing hierarchy.
  #
  # @param [Scope] scope Scope to look for.
  # @return [Boolean] `true` if the scope was found as either a source or
  #     testing scope within this hierarchy or subtrees, and `false` otherwise.
  def contains?(scope)
    @source_scope == scope or @test_scope == scope or
      (instance_variable_defined?(:@subtree) and @subtree.collect { |sth| sth.contains?(scope) }.any?)
  end

  def self.build_subtree(_source_scope, _test_scope)
    o = []
    _source_scope.all_subscopes.each do |ssc|
      o << ScopeTestingHierarchy.new(ssc, _test_scope.subscope('Test' + ssc.name.to_s))
    end
    o
  end

  def /(sym)
    @subtree.select { |el| el.source_scope.name == sym }.first
  end

  # def inspect
  #   source_name = @source_scope.respond_to?(:name) ? @source_scope.name.to_s : @source_scope.inspect
  #   test_name = @test_scope.respond_to?(:name) ? @test_scope.name.to_s : @test_scope.inspect
  #   "#<#{self.class}:#{'%#x' % self.object_id.abs} %s => %s%s>" %
  #     [source_name, test_name, (instance_variable_defined?(:@subtree) and not @subtree.nil?) ? @subtree.inspect : '']
  # end
end

if caller[0].nil?
  source_scope = Scope.new(:global)
  test_scope = Scope.new(:global)
  parse_files(source_files, source_scope)
  parse_files(test_files, test_scope)

  q = ScopeTestingHierarchy.new(source_scope, test_scope)
  test_scope.subscopes(:class, true).select { |ssc| ssc.name =~ /^Test/ }.each { |ssc|
    puts('Orphaned test scope: %s' % ssc.inspect) unless q.contains?(ssc)
  }
  unless ARGV.empty?
    ARGV[0].split('::').each { |el| q = q / el.intern }
  end
    
  cov = q.coverage(true)
  ccov = cov.combine
  icn = ccov.instance_methods_covered.length
  ict = ccov.instance_method_count
  ccn = ccov.class_methods_covered.length
  cct = ccov.class_method_count
  puts('instance methods: %.02f%% (%u/%u)' % [100 * icn.to_f/ict, icn, ict])
  puts('   class methods: %.02f%% (%u/%u)' % [100 * ccn.to_f/cct, ccn, cct])
end
