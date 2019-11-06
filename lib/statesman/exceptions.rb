module Statesman
  class InvalidStateError < StandardError; end
  class InvalidTransitionError < StandardError; end
  class InvalidCallbackError < StandardError; end
  class GuardFailedError < StandardError; end
  class TransitionFailedError < StandardError
    def initialize(from, to)
      @from = from
      @to = to
    end

    attr_reader :from, :to

    def message
      "Cannot transition from '#{from}' to '#{to}'"
    end
  end
  class TransitionConflictError < StandardError; end
  class MissingTransitionAssociation < StandardError; end

  class UnserializedMetadataError < StandardError
    def initialize(transition_class_name)
      super(_message(transition_class_name))
    end

    private

    def _message(transition_class_name)
      "#{transition_class_name}#metadata is not serialized. If you " \
      "are using a non-json column type, you should `include " \
      "Statesman::Adapters::ActiveRecordTransition`"
    end
  end

  class IncompatibleSerializationError < StandardError
    def initialize(transition_class_name)
      super(_message(transition_class_name))
    end

    private

    def _message(transition_class_name)
      "#{transition_class_name}#metadata column type cannot be json " \
      "and serialized simultaneously. If you are using a json " \
      "column type, it is not necessary to `include " \
      "Statesman::Adapters::ActiveRecordTransition`"
    end
  end
end
