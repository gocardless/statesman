require "spec_helper"

shared_examples_for "a SQL adapter" do |adapter_class, transition_class|
  describe "#last" do
    let(:adapter) { adapter_class.new(transition_class, model, observer) }

    before { adapter.create(:x, :y) }

    context "with a previously looked up transition" do
      before { adapter.last }

      it "caches the transition" do
        expect_any_instance_of(model.class).to receive(association_name).never
        adapter.last
      end

      context "and a new transition" do
        before { adapter.create(:y, :z, []) }
        it "retrieves the new transition from the database" do
          expect(adapter.last.to_state).to eq("z")
        end
      end
    end
  end
end
