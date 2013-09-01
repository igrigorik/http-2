module Net
  module HTTP2
    module Emitter
      def add_listener(event, &block)
        raise Exception.new("must provide callback") if !block_given?
        listeners(event.to_sym).push block
      end
      alias :on :add_listener

      def once(event, &block)
        add_listener(event) do |*args|
          block.call(*args)
          :delete
        end
      end

      def emit(event, *args)
        listeners(event).delete_if do |cb|
          cb.call(*args) == :delete
        end
      end

      private

      def listeners(event)
        @listeners ||= Hash.new { |hash, key| hash[key] = [] }
        @listeners[event]
      end
    end
  end
end
