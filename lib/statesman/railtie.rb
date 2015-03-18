module Statesman
  class Railtie < ::Rails::Railtie
    railtie_name :statesman

    rake_tasks do
      load "tasks/statesman.rake"
    end
  end
end
