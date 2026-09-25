# frozen_string_literal: true

require "bundler/gem_tasks"
require "open3"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  task.rspec_opts = []

  if ENV["CIRCLECI"]
    task.rspec_opts += ["--format RspecJunitFormatter",
                        "--out /tmp/test-results/rspec.xml",
                        "--format progress"]
  end
end

DATABASES = %w[sqlite postgres mysql].freeze
RSPEC_COMMAND = %w[bundle exec rspec].freeze

# DB_IMAGE and DATABASE_URL are cleared so each run gets its own database rather than all of them
# sharing whichever one the caller's environment points at.
database_env = ->(db) { { "DB" => (db unless db == "sqlite"), "DB_IMAGE" => nil, "DATABASE_URL" => nil } }

namespace :spec do
  DATABASES.each do |db|
    desc "Run specs against #{db}"
    task(db) { sh(database_env.call(db), *RSPEC_COMMAND) }
  end

  desc "Run specs against all databases in parallel"
  task :all do
    output_lock = Mutex.new

    results = DATABASES.map do |db|
      Thread.new do
        output, status = Open3.capture2e(database_env.call(db), *RSPEC_COMMAND)
        output_lock.synchronize { puts "==> #{db}", output }
        [db, status.success?]
      end
    end.map(&:value)

    failed = results.reject { |_, success| success }.map(&:first)
    abort "Specs failed for: #{failed.join(', ')}" if failed.any?
  end
end

task default: "spec:all"
