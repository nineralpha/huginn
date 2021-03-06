=begin
Usage Example:

class Agents::ExampleAgent < Agent
  include LongRunnable

  # Optional
  #   Override this method if you need to group multiple agents based on an API key,
  #   or server they connect to.
  #   Have a look at the TwitterStreamAgent for an example.
  def self.setup_worker; end

  class Worker < LongRunnable::Worker
    # Optional
    #   Called after initialization of the Worker class, use this method as an initializer.
    def setup; end

    # Required
    #  Put your agent logic in here, it must not return. If it does your agent will be restarted.
    def run; end

    # Optional
    #   Use this method the gracefully stop your agent but make sure the run method return, or
    #   terminate the thread.
    def stop; end
  end
end
=end
module LongRunnable
  extend ActiveSupport::Concern

  included do |base|
    AgentRunner.register(base)
  end

  def start_worker?
    true
  end

  def worker_id(config = nil)
    "#{self.class.to_s}-#{id}-#{Digest::SHA1.hexdigest((config.presence || options).to_json)}"
  end

  module ClassMethods
    def setup_worker
      active.map do |agent|
        next unless agent.start_worker?
        self::Worker.new(id: agent.worker_id, agent: agent)
      end.compact
    end
  end

  class Worker
    attr_reader :thread, :id, :agent, :config, :mutex, :scheduler

    def initialize(options = {})
      @id = options[:id]
      @agent = options[:agent]
      @config = options[:config]
    end

    def run
      raise StandardError, 'Override LongRunnable::Worker#run in your agent Worker subclass.'
    end

    def run!
      @thread = Thread.new do
        begin
          run
        rescue SignalException, SystemExit
          stop!
        rescue StandardError => e
          message = "#{id} Exception #{e.message}:\n#{e.backtrace.first(10).join("\n")}"
          AgentRunner.with_connection do
            agent.error(message)
          end
        end
      end
    end

    def setup!(scheduler, mutex)
      @scheduler = scheduler
      @mutex = mutex
      setup if respond_to?(:setup)
    end

    def stop!
      @scheduler.jobs(tag: id).each(&:unschedule)

      if respond_to?(:stop)
        stop
      else
        thread.terminate
      end
    end

    def restart!
      stop!
      setup!(scheduler, mutex)
      run!
    end

    def every(*args, &blk)
      schedule(:every, args, &blk)
    end

    def cron(*args, &blk)
      schedule(:cron, args, &blk)
    end

    def schedule_in(*args, &blk)
      schedule(:schedule_in, args, &blk)
    end

    def boolify(value)
      agent.send(:boolify, value)
    end

    private
    def schedule(method, args, &blk)
      @scheduler.send(method, *args, tag: id, &blk)
    end
  end
end
