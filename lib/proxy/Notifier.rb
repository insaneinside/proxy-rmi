require 'thread'

module Proxy
  # Cross-thread event notification utility.  Notifier uses an internal Mutex/ConditionVariable
  # pair to facilitate notification of events and communication of values across threads.
  class Notifier
    @result = nil
    @mutex = nil
    @condition_variable = nil
    @signalled = nil

    # Initialize the notifer's internal machinery.
    def initialize()
      @signalled = false
      @result = nil
      @mutex = Mutex.new
      @condition_variable = ConditionVariable.new
    end

    # Notify any threads waiting on this object, optionally with a result value.
    #
    # @param [Object,nil] arg An optional value that will be returned from waiting threads'
    #     calls to `wait`.
    def signal(arg = nil)
      @mutex.synchronize do
        @signalled = true
        @result = arg
        @condition_variable.broadcast()
      end
    end

    # Wait for another thread to call `signal` on this object.
    #
    # @return [Object,nil] Any argument passed to the call to `signal` that wakes the current
    #     thread.
    def wait()
      @mutex.synchronize { @condition_variable.wait(@mutex) if not @signalled }
      @result
    end
  end
end
