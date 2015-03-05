#!/usr/bin/env ruby

# Example demonstrating use of ProxyRMI over a program's stdin/stdout.

require 'open3'
require_relative '../lib/proxy.rb'

# Set VERBOSE to `true` to enable verbose output from the ProxyRMI object nodes.
VERBOSE = false

if ARGV.empty?
  # Note that we've reversed the names usually given to the input and output
  # pipes in the block parameters here; the usual names refer to how the
  # *other* program uses each pipe, but for clarity this example names them
  # according to how the local (current) program makes use of them.
  Open3.popen2($0, 'client') do |outp, inp, thr|
    serv = Proxy::Server.new([inp, outp], verbose: VERBOSE)
    serv.add(:some_string, 'Hello, Interwebs!')
    (0...26).each { |i| serv.add((i+'a'.ord).chr.intern, i) }
    serv.run()
  end
else
  cli = Proxy::Client.new([$stdin, $stdout], verbose: VERBOSE)
  
  cli.list_exports.each { |id| $stderr.puts('%s: %s' % [id, cli[id].inspect]) }
  cli.send_message(:shutdown)
  cli.close()
end
