#!/usr/bin/env ruby

# Basic comparison of dRuby and ProxyRMI, with both operating over TCP.

Thread.abort_on_exception = true

def make_proxy_block_recursive_test_class(_max_depth)
  Class.new do |klass|
    klass.const_set(:MAX_DEPTH, _max_depth)

    # Helper for killing the DRb server when we're done with it.  Since we use
    # `fork` and control everything from one process, we need an easy way to
    # stop DRb remotely.
    def assassinate_drb
      DRb.thread.kill()
    end

    # The actual test method.
    def some_method(depth, *a, &block)
      if block_given?
        if depth < self.class.const_get(:MAX_DEPTH)
          block.call(depth + 1) { |_depth, &blk| some_method(_depth, &blk) }
        else
          block.call(depth)
        end
      else
        depth
      end
    end
  end
end

N = 10000
DEPTH = 10
VERBOSE = false
# ADDRESS = '0.0.0.0'
ADDRESS = '192.168.0.196'
PORT = 12345

DRB_SERVER_URI1 = "druby://#{ADDRESS}:#{PORT + 1}"
DRB_SERVER_URI2 = "druby://#{ADDRESS}:#{PORT + 2}"


# Map basic concepts onto each of the two libraries
ConceptMap =
  {
    :fetch => { :drb => proc { DRbObject.new_with_uri(DRB_SERVER_URI1) },
                :proxy => proc { |cli| cli.fetch() },
           },
    :invoke => { :drb => proc { |obj| obj.some_method(0) { |depth, &block| block_given? ? block.call(depth + 1, *((1..depth).to_a), &block) : depth } },
              :proxy => proc { |cli, obj| obj.some_method(0) { |depth, &block| block_given? ? block.call(depth + 1, *((1..depth).to_a), &block) : depth } },
            }
  }

begin
  method(:require_relative).nil?
rescue
  def self.require_relative(path)
    require(File.join(File.dirname(caller[0]), path.to_s))
  end
end
def test(tt, which, *a)
  tt.time(:fetch) { N.times { ConceptMap[:fetch][which].call(*a) } } if ConceptMap[:fetch].has_key?(which)
  obj = ConceptMap[:fetch][which].call(*a)
  a.push(obj)
  tt.time(:invoke) { N.times { ConceptMap[:invoke][which].call(*a) } } if ConceptMap[:invoke].has_key?(which)
end


if Process.fork
  FRONT_OBJECT = make_proxy_block_recursive_test_class(DEPTH).new

  require_relative '../lib/proxy'
  require 'drb'

  serv = nil
  begin
    serv = Proxy::Server.new(TCPServer, ADDRESS, PORT) # Create the proxy server.
    serv.front = FRONT_OBJECT
    serv.on_client_disconnect { serv.kill() }
    serv.verbose = VERBOSE
    serv.launch()
    serv.wait()

    DRb.start_service(DRB_SERVER_URI1, FRONT_OBJECT)
    DRb.thread.join()

  ensure
    DRb.thread.kill() unless DRb.thread.nil? or not DRb.thread.alive?
    serv.halt() if not serv.nil? and serv.running?
  end


else
  require_relative 'helpers/TimeTable.rb'
  require_relative 'helpers/Table.rb'

  tt = IINet::Util::TimeTable.new(false)

  # Just for fun, let's also check how long each one takes to load.
  tt.time(:load_proxy, 'loading ProxyRMI') { require_relative '../lib/proxy.rb' }
  tt.time(:load_drb, 'loading dRuby') { require 'drb' }
  tt.clear()


  sleep(0.5)
  tab = Table.new(['', 'fetch', 'invoke'])

  sleep(0.1)


  # Run the tests for ProxyRMI.
  cli = Proxy::Client.new(TCPSocket, ADDRESS, PORT)
  cli.verbose = VERBOSE

  test(tt, :proxy, cli)
  tab << [:proxy, tt.actions[:fetch].time, tt.actions[:invoke].time ]
  pr_invoke_time = tt.actions[:invoke].time
  tt.clear()
  cli.send_message(:shutdown)
  cli.close()


  sleep(0.5)
  # Run the tests with dRuby.
  DRb.start_service(DRB_SERVER_URI2)
  test(tt, :drb)
  tab << [:drb, tt.actions[:fetch].time, tt.actions[:invoke].time ]
  drb_invoke_time = tt.actions[:invoke].time
  tt.clear()

  begin
    DRbObject.new_with_uri(DRB_SERVER_URI1).assassinate_drb()
  rescue
  end

  puts tab.render(true)

  puts("\nProxyRMI invocation time is %.02f%% of dRuby's." % (100 * pr_invoke_time / drb_invoke_time))
  puts(<<EOF
The *fetch* times swing wildly in favor of dRuby here because it doesn't
actually connect to the server until a method is called on a remote-object
reference; ProxyRMI has not (yet!) implemented such an optimization.
EOF
      )
end
