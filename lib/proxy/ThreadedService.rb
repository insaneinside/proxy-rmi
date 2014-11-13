require 'thread'

module Proxy
  # Mixin for use with classes that provide some sort of service via a
  # dedicated thread; ThreadedService provides methods for managing that
  # thread.
  #
  # Cross-thread notification of changes in service state is provided by
  # a dedicated mutex/condition-variable pair.
  module ThreadedService
    @service_mutex = nil
    @service_notifier_mutex = nil
    @service_notifier_cv = nil
    @service_thread = nil
    @service_main_method = nil
    @service_halt_method = nil

    # Set up the ThreadedService with the implementation methods.
    def initialize(_main_method, _halt_method)
      @service_mutex = Mutex.new
      @service_notifier_mutex = Mutex.new
      @service_notifier_cv = ConditionVariable.new
      @service_thread = nil
      @service_main_method = _main_method
      @service_halt_method = _halt_method
    end

    # @!attribute [r] running?
    #   Whether the node's service thread is currently running.
    #   @return [Boolean]
    def running?
      @service_mutex.locked?
    end


    # Start the service loop in a separate thread.
    # @return [Boolean] `true` if a new thread was created, and `false` if it was already
    #     running.
    def launch()
      @service_thread = Thread.new { run() } unless running?
    end

    # Run the service loop in the current thread.  If the server is already
    # running in a different thread, this call will block until that thread
    # exits.
    def run()
      if not running?
        # Thread.current.set_trace_func proc { |event, file, line, id, binding, classname|
        #   printf "%8s %s:%-2d %10s %8s\n", event, file, line, id, classname
        # }
        @x = 0 unless instance_variable_defined?(:@x)
        @service_mutex.synchronize do
          @service_thread = Thread.current
          begin
            @service_main_method.call()
          ensure
            @service_notifier_mutex.synchronize { @service_notifier_cv.broadcast() }
          end
          @service_thread = nil
        end
      else
        if Thread.current == @service_thread
          raise 'Illegal recursive call to `run()`'
        else
          wait()
        end
      end
    end


    # Kill the service thread.  This is a ruder version of {#halt}.
    def kill()
      @service_halt_method.call()
      if Thread.current == @service_thread
        Thread.exit()
      else
        @service_thread.kill() if not @service_thread.nil? and @service_thread.alive?
      end
    end

    # Halt the service thread gracefully.
    def halt()
      @service_halt_method.call()
      wait() unless Thread.current == @service_thread
    end

    # Wait for the service thread to finish.
    def wait()
      raise 'Invalid call to `wait()` from service thread!' if Thread.current == @service_thread
      if ! @service_thread.nil? and @service_thread.alive?
        if @service_thread != Thread.main
          @service_thread.join()
        else
          @service_notifier_mutex.synchronize { @service_notifier_cv.wait(@service_notifier_mutex) }
        end
      end
    end
  end    
end
