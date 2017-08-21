require "spec_helper"

describe Statesman::Guard do
  let(:callback) { -> {} }
  let(:guard) { Statesman::Guard.new(from: nil, to: nil, callback: callback) }

  specify { expect(guard).to be_a(Statesman::Callback) }

  describe "#call" do
    subject(:call) { guard.call }

    context "success" do
      let(:callback) { -> { true } }
      specify { expect { call }.to_not raise_error }
    end

    context "error" do
      let(:callback) { -> { false } }

      it "raises a GuardFailedError with no name" do
        expect { call }.to raise_error do |error|
          expect(error).to be_a(Statesman::GuardFailedError)
          expect(error.guard_name).to be_nil
        end
      end

      context "when the guard has a name specified" do
        let(:guard) do
          Statesman::Guard.new(from: nil, to: nil, callback: callback,
                               name: :arbitrary_name)
        end

        it "raises a GuardFailedError with the guard's name accessible" do
          expect { call }.to raise_error do |error|
            expect(error).to be_a(Statesman::GuardFailedError)
            expect(error.guard_name).to be(:arbitrary_name)
          end
        end
      end
    end
  end
end
