require 'spec_helper'

describe PgLock do
  it 'has a version number' do
    expect(PgLock::VERSION).not_to be nil
  end

  it "lock! raises an error" do
    key = testing_key("lock! raises an error")
    out = ""
    PgLock.new(name: key).lock do
      out = run("env PG_LOCK_KEY='#{ key }' bundle exec ruby #{ PgLockSpawn.fixture_path("lock!.rb") }")
    end
    expect_output_has_message(out: out, count: 1, msg: "PgLock::UnableToLockError")
  end

  it "lock! can be called without raising an error" do
    key = testing_key("lock! does not raise an error")
    out = run("env PG_LOCK_KEY='#{key}' SLEEP_FOR=0 bundle exec ruby #{PgLockSpawn.fixture_path("lock!.rb")}")

    expect_output_has_message(out: out, count: 1, msg: "done with lock!")
  end

  it "attempts" do
    max_attempts = rand(2..9)
    key          = testing_key("attempts")
    # x attempts
    # Note mocking out `lock` returns nil` which forces the lock aquire to fail
    fails_to_lock = PgLock.new(name: key, attempts: max_attempts)
    expect(fails_to_lock.send(:locket)).to receive(:lock).exactly(max_attempts).times
    fails_to_lock.lock {}

    # 0 attempts should try once
    fails_to_lock = PgLock.new(name: key, attempts: 0)
    expect(fails_to_lock.send(:locket)).to receive(:lock).exactly(1).times
    fails_to_lock.lock {}
  end

  it 'return_result' do
    key  = testing_key("return_result")
    expect(PgLock.new(name: key, return_result: true).lock { 'result' }).to eq('result')
  end

  it "ttl" do
    key  = testing_key("ttl")
    time = rand(2..4)
    expect {
      PgLock.new(name: key, ttl: time).lock do
        sleep time + 0.1
      end
    }.to raise_error(Timeout::Error)
  end

  it "log" do
    key = testing_key("log")
    log = ->(data) {}
    expect(log).to receive(:call).with(hash_including(at: :create, pg_lock: true))
    expect(log).to receive(:call).with(hash_including(at: :delete, pg_lock: true))
    PgLock.new(name: key, log: log).lock {}
  end

  it "default log" do
    key = testing_key("default log")
    begin
      original = defined?(PgLock::DEFAULT_LOG) ? PgLock::DEFAULT_LOG : nil

      PgLock::DEFAULT_LOG = ->(data) {}
      expect(PgLock::DEFAULT_LOG).to receive(:call).with(hash_including(at: :create, pg_lock: true))
      expect(PgLock::DEFAULT_LOG).to receive(:call).with(hash_including(at: :delete, pg_lock: true))
      PgLock.new(name: key).lock {}
    ensure
      PgLock::DEFAULT_LOG = original
    end
  end

  it "acquires correctly" do
    key = testing_key("acquired_test")

    begin
      lock = PgLock.new(name: key).create

      expect(lock.acquired?).to be true
      expect(lock.aquired?).to be true
    ensure
      lock.delete
    end
  end

  it "only runs X times" do
    begin
      count = rand(2..9)
      log   = PgLockSpawn.new_log_file
      10.times.map do
        Process.spawn("env COUNT=#{count} bundle exec ruby #{PgLockSpawn.fixture_path("run_x_times.rb")} >> #{log}")
      end.each do |pid|
        Process.wait(pid)
      end
      expect_log_has_count(log: log, count: count)
    ensure
      FileUtils.remove_entry_secure log
    end
  end

  it "only runs once" do
    begin
      log = PgLockSpawn.new_log_file
      5.times.map do
        Process.spawn("bundle exec ruby #{PgLockSpawn.fixture_path("lock_once.rb")} >> #{log}")
      end.each do |pid|
        Process.wait(pid)
      end
      expect_log_has_count(log: log, count: 1)
    ensure
      FileUtils.remove_entry_secure log
    end
  end

  it 'does not raise an error' do
    PgLock.new(name: testing_key("foo")) do
      puts 1
    end
    expect(true).to eq(true)
  end

  it 'returns false from acquired? when lock is not acquired' do
    key = testing_key('not_acquired_test')

    lock = PgLock.new(name: key)
    acquired = lock.acquired?

    expect(lock.acquired?).to be false
    expect(lock.aquired?).to be false
  end

  it 'is unlocked when exception is raised during logging' do
    exception = Class.new(StandardError)
    key = testing_key("log_exception_test")

    begin
      lock = PgLock.new(name: key, log: -> (_) { raise exception })
      lock.lock do
        puts 1
      end
    rescue exception
      expect(lock.acquired?).to be false
    ensure
      # PgLock.new(name: key).delete
    end
  end

  it 'acquires transaction lock' do
    key = testing_key('acquired_for_transaction_test')

    connection = ActiveRecord::Base.connection.raw_connection
    lock = PgLock.new(name: key, connection: connection)

    connection.exec('BEGIN')
    lock.lock_for_transaction
    sleep(1)
    expect(lock.acquired?).to be true
    sleep(1)
    connection.exec('COMMIT')
    expect(lock.acquired?).to be false
  end

  it 'no lock acquired when acquiring trasaction lock outside of a transaction' do
    key = testing_key('acquired_for_transaction_test')

    connection = ActiveRecord::Base.connection.raw_connection
    lock = PgLock.new(name: key)

    lock.lock_for_transaction
    expect(lock.acquired?).to be false
  end
end
