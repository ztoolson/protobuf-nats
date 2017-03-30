require "protobuf/nats"
require "protobuf/rpc/connectors/base"
require "monitor"

module Protobuf
  module Nats
    class Client < ::Protobuf::Rpc::Connectors::Base
      def initialize(options)
        # may need to override to setup connection at this stage ... may also do on load of class
        super

        # This will ensure the client is started.
        ::Protobuf::Nats.start_client_nats_connection
      end

      def close_connection
        # no-op (I think for now), the connection to server is persistent
      end

      def self.subscription_key_cache
        @subscription_key_cache ||= {}
      end

      def send_request
        retries ||= 3

        setup_connection
        request_options = {:timeout => 60, :ack_timeout => 5}
        @response_data = nats_request_with_two_responses(cached_subscription_key, @request_data, request_options)
        parse_response
      rescue ::NATS::IO::Timeout
        # Nats response timeout.
        retry if (retries -= 1) > 0
        raise
      end

      def cached_subscription_key
        klass = @options[:service]
        method_name = @options[:method]

        method_name_cache = self.class.subscription_key_cache[klass] ||= {}
        method_name_cache[method_name] ||= begin
          ::Protobuf::Nats.subscription_key(klass, method_name)
        end
      end

      # This is a request that expects two responses.
      # 1. An ACK from the server. We use a shorter timeout.
      # 2. A PB message from the server. We use a longer timoeut.
      def nats_request_with_two_responses(subject, data, opts)
        nats = Protobuf::Nats.client_nats_connection
        inbox = nats.new_inbox
        lock = ::Monitor.new
        ack_condition = lock.new_cond
        pb_response_condition = lock.new_cond
        response = nil
        sid = nats.subscribe(inbox, :max => 2) do |message|
          lock.synchronize do
            case message
            when ::Protobuf::Nats::Messages::ACK
              ack_condition.signal
              next
            else
              response = message
              pb_response_condition.signal
            end
          end
        end

        lock.synchronize do
          # Publish to server
          nats.publish(subject, data, inbox)

          # Wait for the ACK from the server
          ack_timeout = opts[:ack_timeout] || 5
          with_timeout(ack_timeout) { ack_condition.wait(ack_timeout) }

          # Wait for the protobuf response
          timeout = opts[:timeout] || 60
          with_timeout(timeout) { pb_response_condition.wait(timeout) } unless response
        end

        response
      ensure
        # Ensure we don't leave a subscription sitting around.
        nats.unsubscribe(sid) if response.nil?
      end

      # This is a copy of #with_nats_timeout
      def with_timeout(timeout)
        start_time = ::NATS::MonotonicTime.now
        yield
        end_time = ::NATS::MonotonicTime.now
        duration = end_time - start_time
        raise ::NATS::IO::Timeout.new("nats: timeout") if duration > timeout
      end

    end
  end
end
