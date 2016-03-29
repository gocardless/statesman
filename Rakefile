require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  if ENV["EXCLUDE_MONGOID"]
    task.rspec_opts = "--tag ~mongo --exclude-pattern **/*mongo*"
  end
end

task default: :spec
