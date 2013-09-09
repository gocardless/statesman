require "spec_helper"

describe Statesman::Transition do
  describe "#initialize" do
    let(:from) { :x }
    let(:to) { :y }
    let(:create) { Statesman::Transition.new(from, to) }

    specify { expect(create.from).to equal(from) }
    specify { expect(create.to).to equal(to) }
    specify { expect(create.created_at).to be_a(Time) }
  end
end
