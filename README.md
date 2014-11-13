# ProxyRMI: fast and flexible dRuby alternative

I'm told that dRuby isn't very relevant anymore in most areas, having been
replaced by tools more suitable to the respective tasks at hand; that would
probably make this project itself obsolete.

So, then, for what it's worth:

> ProxyRMI is non-judgemental.  
  ProxyRMI is fast.  
  ProxyRMI loves you.

ProxyRMI is probably best described as a modern take on dRuby.

It is **not** ready for release; among the current deficiencies are
insufficient testing and numerous gaps in the security model.


## Features

  * Fast!  ProxyRMI is 35–40% faster than dRuby, *without* resorting to native
    code to provide this advantage. (See sample/drb-comparison.rb.)

    Why?

    - Lock-free communication.  ProxyRMI uses mutexes *only* for waiting on
      service threads, preferring atomics for shared variable access.
      In contrast, dRuby locks a *global* mutex (`DRb.mutex`) for *every*
      message received.

    - Connection reuse.  dRuby opens a new connection *for each remote method
      call*; ProxyRMI opens a single connection for each client/server pair and
      uses it for all session communication.

  * If it talks, it walks.  ProxyRMI supports as many transports as there are
    descendants of Ruby's `IO` class, and **no additional code** is required
    (see next point, "DRY").

    Standard input/output?  Sure, we can do that:

    ```ruby
    require 'proxy'
    require 'open3'

    if ARGV.empty?
      def some_method(name)
        "Hello, #{name}!"
      end

      Open3.popen2(__FILE__, 'client') do |outp, inp, thr|
        serv = Proxy::Server.new([inp, outp])
        serv.front = method(:some_function)
        serv.run()
      end
    else
      cli = Proxy::Client.new([$stdin, $stdout])
      $stderr.puts(cli.fetch().call("Interwebs"))
      cli.send_message(:shutdown)
      cli.close()
    end
    ```

    UNIX sockets? Piece of cake.  And we'll do it all in one process, just for fun.

    ```ruby
    require 'proxy'

    SOCKET_FILE = 'foo.sock'

    def some_method(&block)
      "Hello, #{block.call()}!"
    end

    serv = nil
    cli = nil
    begin
      serv = Proxy::Server.new(UNIXServer, SOCKET_FILE)
      serv.front = method(:some_method)
      serv.launch()

      sleep(0.1)

      cli = Proxy::Client.new(UNIXSocket, SOCKET_FILE)
      cli.fetch().call { $0 }
    ensure
      require 'fileutils'
      FileUtils::rm_f(SocketFile)
      cli.close() unless cli.nil?
      serv.halt() unless serv.nil?
    end
    ```

    It's a little more nuanced than this since duck-typing is used, but
    anything with `#read` and `#write` should, in theory, work.

  * DRY code.  As seen above, ProxyRMI doesn't obfuscate I/O with silly URI
    schemes (which dRuby uses solely for providing a pretty way to specify what
    kind of socket to use).  We won't even discuss dRuby's ever-so-delightful
    `DRb::DRb` idiom here.

  * Modern, reusable, and cringe-free API — no modifications to your
    previously-written classes are are necessary for use with ProxyRMI (class-
    and method-attribute data isn't an intrusive mixin).

  * We understand what ProxyRMI's code does.  But we wonder what `DRbURIOption`
    is used for, and
    [so do the dRuby authors](http://yard.ruby-doc.org/stdlib/DRb/DRbURIOption.html).
    That's just a little bit scary.


## Other Important Differences from dRuby

In dRuby, messages send themselves using a new connection for each message.
That design decision was more than just a little silly: it greatly affected how
the rest of the library was built.

### Remote-Reference Handling and Resolution: An Issue of Security

For example, when a dRuby-based client needs to pass a non-marshallable object
(as an argument or block) to a remote method, it needs to start its *own*
server to handle remote calls to that object (because existing dRuby
connections are not available for reuse).  This creates a remarkable hole in
the client's security: **by default, an attacker can invoke methods on *any*
object, exported or not, in the same Ruby context (process) as a dRuby
server.** This is a consequence of how
[`DRb::DRbIdConv`, the default remote-reference resolution mechanism](http://www.ruby-doc.org/stdlib/libdoc/drb/rdoc/DRb/DRbIdConv.html),
is implemented; dRuby does *not* keep track of which objects it has exported to
remote peers.  Indeed, tracking each peer could be a complex task because of
the way dRuby discards connections after each remote method call.

The design of ProxyRMI made it simple to protect against this problem.
Because each instance of `ObjectNode`, the per-session connection holder,
stores local references to exported objects (to avoid the garbage-collection
issues discussed in
[this dRuby example](http://www.ruby-doc.org/stdlib/libdoc/drb/rdoc/DRb.html#module-DRb-label-Remote+objects+under+dRuby)),
it is easy to check if the target of a requested method invocation has been
previously exported.


## Basic API components

ProxyRMI uses the `Proxy` module namespace (for now):

```ruby
require 'proxy'
```

Any IO-like object can be used as a transport by passing it as the first
argument to `Proxy::ObjectNode.new`, `Proxy::Server.new`, or
`Proxy::Client.new`.

  * `ObjectNode` contains most of the object-proxy logic, and may be useful as
    a base for custom classes.  To relieve the developer of the burden of
    reference management, it manages a table of remotely-held proxy objects for
    local objects, and makes use of object finalizers on locally-held proxies
    to release remote objects.

    ObjectNode's initializer accepts either a class to instantiate, plus
    arguments to supply when instantiating it

    ```ruby
    ObjectNode.new(TCPSocket, '192.168.0.100', 1234)
    ```

    or an instance (or two) of an IO-like object:

    ```ruby
    ObjectNode.new(TCPSocket.new('192.168.0.100', 1234))
    ObjectNode.new([$stdin, $stdout])  # note the array!
    ```

    In the latter usage, the ObjectNode instance will use the separate streams
    for input and output.  Note that because Ruby is slightly braindead and
    uses standard output for things like the `p` object-inspection method
    (which should use standard error instead), we need to be careful about what
    methods we call.

  * `Server` implements a mechanism for exporting an enumerable list of named
    objects to connection peers.  In addition to the instantiation styles
    supported by ObjectNode, it also provides support for multi-connection
    server functionality:

    ```ruby
    server = Proxy::Server.new(TCPServer, '0.0.0.0', 1234)
    ```

    Server-like usage is chosen whenever the first argument to `new` is a class
    _and_ responds to `open`.

  * `Client` extends ObjectNode with methods `list_exports()`, which requests a
    list of the object names exported by a Server instance, and `fetch(name)`,
    aliased as `[]`, which fetches a particular exported object by name.


## Migrating from dRuby

### Why You Shouldn't

ProxyRMI is *not* designed for the same use-cases as dRuby; specifically, it is
meant for communication betweeen node pairs.

Suppose we have three nodes: one server S, and two clients A and B.  S exports
a non-copyable object `s`, which has gettable/settable attribute `attr`, and
client A sets this attribute to `a`, which is a non-copyable object local to
node A.  B now fetches `s` and invokes `attr`, storing the result locally.

There are now three objects that represent `a`:  `a` itself, which resides on
A; the object stored by `s.attr=`, which is a proxy object on S that points to
the actual `a` on node A; and the object stored by B, which is a proxy (on B)
pointing to the the proxy for `a` that resides on S.

Now when client B calls `s.attr.inspect()` the `inspect` call will be proxied
to the server node S and a second invoke message will be fired by
`s.attr.method_missing`, since (on S) `s.attr` is a `Proxy::Object`.  At best
this will be inefficient.

dRuby, however, is designed for this scenaro — since it has additional code
specialized for each supported transport, it knows how to avoid such
double-indirections.  ProxyRMI may support something similar via a crude
heuristic in the future, but has nothing comparable right now.

### Why You Should

ProxyRMI *is* designed for instances where communication

  * must be possible over arbitrary I/O streams that are not necessarily
    sockets,
  * needs to be done using separate streams for input and output, or
  * must allow for remote methods that call functions like `exit` or `exec`,
    which don't return and would normally cause a DRb-based program to
    block indefinitely.

One real-life scenario where ProxyRMI was useful involved another (non-Ruby)
script initiating communication over a protocol poorly supported in Ruby,
assigning the file descriptor to its standard input and output, and then
executing a ProxyRMI-based script that used the standard I/O streams
for communication.

## This code may break _everything_

and the author provides no guarantees of safety, suitability, _or_ sanity for a
particular purpose.  ProxyRMI is still undergoing some changes in its API, and
is by no means stable enough to use in production code unless you are willing
to pick up the pieces.  Only minimal support can be provided by the author at
the current time.

ProxyRMI currently has no support for sharing a local proxy for an object that
lives on one remote node to a third-party node.  Because its connection scheme
is not necessarily heterogenous (it's designed more for flexibility instead of
consistency), any such support would likely be inefficient in the general case.


## Install
This gem has not been uploaded to the (or any) RubyGems repository; to build
and install it, use the following commands.

```shell
gem build proxy-rmi.gemspec && gem install ProxyRMI-0.2.0.gem
```

Inserting `--user-install` after `install` will allow you to install the gem
into your user gems directory.


## Legalese
ProxyRMI is licensed under the GNU General Public License v2.
