require "spec_helper"
require "statesman/adapters/shared_examples"

describe Statesman::Adapters::Sequel, sequel: true do
  it_behaves_like "an adapter", described_class, MySequelModelTransition
end
