module Statesman
  module GeneratorHelpers
    def is_mysql?
      ActiveRecord::Base.configurations[Rails.env]["adapter"].match(/mysql/)
    end
  end
end
