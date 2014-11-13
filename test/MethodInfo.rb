class MethodInfo
  @@instance_variable_dump_order = [:@name, :@parameters, :@arity]

  attr_reader :name, :parameters, :arity

  def initialize(m)
    if m.respond_to?(:name)
      @name = m.name.to_s
    else
      unless (rm = /^#<(?:Unbound)?Method: ([^#(]+)(\([^)]+\))?[#.]([^>]+)>$/.
              match(m.inspect)).nil?
        @name = rm[3]
      end
    end

    if m.respond_to?(:parameters)
      @parameters = m.parameters
    else
      @arity = m.arity
    end
  end      

  def to_s
    args_string =
      if instance_variable_defined?(:@parameters)
        @parameters.collect do |p|
          case p[0]
          when :req
            p[1].to_s
          when :opt
            '%s = ...' % p[1]
          when :rest
            '*%s' % p[1]
          when :block
            '&%s' % p[1]
          end
        end.join(', ')
      else
        if @arity < 0
          num_reqd_parameters = @arity.abs - 1
          params = []
          argname = 'a'
          while num_reqd_parameters > 0
            params << argname
            argname.next!
            num_reqd_parameters -= 1
          end
          params << '...'
          params.join(', ')
        else
          'a'.upto('z').to_a()[0...@arity].join(', ')
        end
      end      
    '%s(%s)' % [@name, args_string]
  end

  def inspect
    "#<#{self.class}:#{'%#x' % self.object_id.abs} %s>" % [to_s]
  end
end
