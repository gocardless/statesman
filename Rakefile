require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  task.rspec_opts = []

  if ENV["CIRCLECI"]
    task.rspec_opts += ["--format RspecJunitFormatter",
                        "--out /tmp/test-results/rspec.xml",
                        "--format progress"]
  end
end

task default: :spec
