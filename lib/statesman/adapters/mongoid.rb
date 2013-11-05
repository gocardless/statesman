require_relative "../exceptions"

module Statesman
  module Adapters
    class Mongoid
      attr_reader :transition_class
      attr_reader :parent_model

      def initialize(transition_class, parent_model)
        @transition_class = transition_class
        @parent_model = parent_model
        unless transition_class_hash_fields.include?('statesman_metadata')
          raise UnserializedMetadataError, metadata_field_error_message
        end
      end

      def create(to, before_cbs, after_cbs, metadata = {})
        transition = transitions_for_parent.build(to_state: to,
                                                  sort_key: next_sort_key,
                                                  statesman_metadata: metadata)

        before_cbs.each { |cb| cb.call(@parent_model, transition) }
        transition.save!
        after_cbs.each { |cb| cb.call(@parent_model, transition) }
        @last_transition = nil
        transition
      end

      def history
        transitions_for_parent.asc(:sort_key)
      end

      def last
        @last_transition ||= history.last
      end

      private

      def transition_class_hash_fields
        transition_class.fields.select { |k, v| v.type == Hash }.keys
      end

      def metadata_field_error_message
        "#{transition_class.name}#statesman_metadata is not of type 'Hash'"
      end

      def transitions_for_parent
        @parent_model.send(@transition_class.collection_name)
      end

      def next_sort_key
        (last && last.sort_key + 10) || 0
      end
    end
  end
end
