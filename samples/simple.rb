#!/usr/bin/ruby -W

# This file illustrates basic use of ProxyRMI with sockets from the 'socket'
# library and a test object that gets passed by value.

# We fork the process, and then continue as either a proxy server, or as
# a client to that server.  The server exports a single value -- the
# alphabet -- and the client fetches and pretty-prints it.

require 'fileutils'
require_relative '../lib/proxy.rb'

# Set VERBOSE to `true` to enable verbose output from the ProxyRMI object nodes.
VERBOSE = false

# Possible values here are TCP, UDP, and UNIX.  We combine this prefix with
# either 'Server' or 'Socket' to get the name of the transport class used by
# the server or client, respectively.
TRANSPORT = 'UNIX'

SocketFile = 'foo.sock'

$stdout.print("PIDs: server #{Process.pid}, ")
begin
  if Process.fork()
    server_socket_type = Object.const_get((TRANSPORT+'Server').intern)
    begin
      # Create the proxy server.
      serv = Proxy::Server.new(server_socket_type,
                               SocketFile, VERBOSE)
      # Add the alphabet.
      serv.add(:alphabet, ('a'..'z').to_a)

      # Run until told to shut down.
      serv.run()
    ensure
      FileUtils::rm_f(SocketFile)
    end
  else
    $stderr.puts("client #{Process.pid}")
    client_socket_type = Object.const_get((TRANSPORT+'Socket').intern)

    # Wait for the server to initialize.
    sleep(0.5)

    # Create client/connect to server.
    cli = Proxy::Client.new(client_socket_type, SocketFile, VERBOSE)

    $stdout.puts('Server exports list: ' + cli.list_exports.inspect)

    $stdout.puts('Look!  I found the ALPHABET: %s' % cli.fetch(:alphabet).inspect)
    cli.send_message(:shutdown) # tell the server to shut down
    cli.close
  end
rescue Exception => e
  $stderr.puts('%u: %s' % [Process.pid, e.inspect])
  $stderr.puts('    ' + e.backtrace.join("\n    "))
end

$stdout.sync = true
$stdout.puts("#{Process.pid} exiting.")
$stdout.flush()
