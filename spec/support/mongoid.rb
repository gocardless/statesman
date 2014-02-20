require 'mongoid'

Mongoid.configure do |config|
  config.connect_to('statesman_test')
end

class MyMongoidModel
  include Mongoid::Document

  has_many :my_mongoid_model_transitions
end

class MyMongoidModelTransition
  include Mongoid::Document

  field :to_state, type: String
  field :sort_key, type: Integer
  field :statesman_metadata, type: Hash

  index(sort_key: 1)

  belongs_to :my_mongoid_model, index: true

  alias_method :metadata, :statesman_metadata
  alias_method :metadata=, :statesman_metadata=
end
