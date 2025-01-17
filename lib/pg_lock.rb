require 'zlib'
require 'timeout'

require "pg_lock/version"

class PgLock
  PG_LOCK_SPACE      = -2147483648
  DEFAULT_CONNECTION_CONNECTOR = Proc.new do
    if defined?(DEFAULT_CONNECTION)
      DEFAULT_CONNECTION
    elsif defined?(ActiveRecord::Base)
      ActiveRecord::Base.connection.raw_connection
    else
      false
    end
  end

  DEFAULT_LOGGER     = Proc.new do
    defined?(DEFAULT_LOG) ? DEFAULT_LOG : false
  end

  class UnableToLockError < RuntimeError
    def initialize(name:, attempts: )
      msg = "Was unable to aquire a lock #{ name.inspect } after #{ attempts } attempts"
      super msg
    end
  end
  UnableToLock = UnableToLockError
  NO_LOCK = Object.new

  def initialize(name:, attempts: 3, attempt_interval: 1, ttl: 60, connection: DEFAULT_CONNECTION_CONNECTOR.call, log: DEFAULT_LOGGER.call, return_result: true)
    self.name               = name
    self.max_attempts       = [attempts, 1].max
    self.attempt_interval   = attempt_interval
    self.ttl                = ttl || 0 # set this to 0 to disable the timeout
    self.log                = log
    self.return_result      = return_result

    connection or raise "Must provide a valid connection object"
    self.locket             = Locket.new(connection, [PG_LOCK_SPACE, key(name)])
  end

  def lock_for_transaction
    create_transaction_lock
  end

  def lock_for_transaction!(exception_klass = PgLock::UnableToLockError)
    acquired = create_transaction_lock
    raise exception_klass.new(name: name, attempts: max_attempts) unless acquired
    acquired
  end

  # Runs the given block if an advisory lock is able to be acquired.
  def lock(&block)
    result = internal_lock(&block)
    return false if result == NO_LOCK
    result
  end

  # A PgLock::UnableToLock is raised if the lock is not acquired.
  def lock!(exception_klass = PgLock::UnableToLockError)
    result = internal_lock { yield self if block_given? }
    if result == NO_LOCK
      raise exception_klass.new(name: name, attempts: max_attempts)
    end
    return result
  end

  def create
    max_attempts.times.each do |attempt|
      if locket.lock
        log.call(at: :create, attempt: attempt, args: locket.args, pg_lock: true) if log
        return self
      else
        return false if attempt.next == max_attempts
        sleep attempt_interval
      end
    end
  end

  def delete
    locket.unlock
    log.call(at: :delete, args: locket.args, pg_lock: true ) if log
  rescue => e
    if log
      log.call(at: :exception, exception: e, pg_lock: true )
    else
      raise e
    end
  end

  def create_transaction_lock
    max_attempts.times.each do |attempt|
      if locket.lock_for_transaction
        log.call(at: :create_transaction_lock, attempt: attempt, args: locket.args, pg_lock: true) if log
        return self
      else
        return false if attempt.next == max_attempts
        sleep attempt_interval
      end
    end
  end

  # Left the misspelled version of this method for backwards compatibility
  def aquired?
    acquired?
  end

  def acquired?
    locket.active?
  end

  alias :has_lock? :acquired?

  private def internal_lock(&block)
    if create
      result = nil
      result = Timeout::timeout(ttl, &block) if block_given?
      return_result ? result : true
    else
      return NO_LOCK
    end
  ensure
    delete if locket.acquired?
  end

  private
    attr_accessor :max_attempts
    attr_accessor :attempt_interval
    attr_accessor :connection
    attr_accessor :locket
    attr_accessor :ttl
    attr_accessor :name
    attr_accessor :log
    attr_accessor :return_result

    def key(name)
      i = Zlib.crc32(name.to_s)
      # We need to wrap the value for postgres
      if i > 2147483647
        -(-(i) & 0xffffffff)
      else
        i
      end
    end
end

require 'pg_lock/locket'
