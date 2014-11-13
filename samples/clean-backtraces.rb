#!/usr/bin/ruby -W

# ProxyRMI munges backtraces to remove unnecessary information about its
# internal internal code flow --- so you can focus on *your* code, not ours.

require_relative '../lib/proxy.rb'

SOCKET_FILE='foo.sock'

class Foo
  def bar(message)
    raise 'I hate everything go away.'
  end
end

begin
  serv = Proxy::Server.new(UNIXServer, SOCKET_FILE)
  serv.front = Foo.new
  serv.launch()

  sleep(0.25)

  cli = Proxy::Client.new(UNIXSocket, SOCKET_FILE)

  $stderr.puts('Look, Ma!  That there\'s a real pretty backtrace:')

  cli.fetch().bar('I love you!')
  
ensure
  cli.close()
  serv.kill()
  FileUtils.rm_f(SOCKET_FILE)
end
