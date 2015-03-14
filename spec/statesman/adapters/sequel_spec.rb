require "spec_helper"
require "statesman/adapters/shared_examples"

describe Statesman::Adapters::ActiveRecord, sequel: true do
  it_behaves_like "an adapter", described_class, MySequelModelTransition

  it "can create an instance" do
    instance = MySequelModel.create
    expect(instance).to eq(MySequelModel.first)
  end
end
