require 'odata4/service/response/atom'
require 'odata4/service/response/json'
require 'odata4/service/response/plain'
require 'odata4/service/response/xml'

module OData4
  class Service
    # The result of executing a OData4::Service::Request.
    class Response
      include Enumerable

      # The service that generated this response
      attr_reader :service
      # The underlying (raw) response
      attr_reader :response
      # The query that generated the response (optional)
      attr_reader :query

      # Create a new response given a service and a raw response.
      # @param service [OData4::Service] The executing service.
      # @param query [OData4::Query] The related query (optional).
      # @param
      def initialize(service, query = nil, &block)
        @service  = service
        @query    = query
        @timed_out = false
        execute(&block)
      end

      # Returns the HTTP status code.
      def status
        response.status
      end

      # Whether the request was successful.
      def success?
        200 <= status && status < 300
      end

      # Returns the content type of the resonse.
      def content_type
        response.headers['Content-Type'] || ''
      end

      def is_atom?
        content_type =~ /#{Regexp.escape OData4::Service::MIME_TYPES[:atom]}/
      end

      def is_json?
        content_type =~ /#{Regexp.escape OData4::Service::MIME_TYPES[:json]}/
      end

      def is_plain?
        content_type =~ /#{Regexp.escape OData4::Service::MIME_TYPES[:plain]}/
      end

      def is_xml?
        content_type =~ /#{Regexp.escape OData4::Service::MIME_TYPES[:xml]}/
      end

      # Whether the response contained any entities.
      # @return [Boolean]
      def empty?
        @empty ||= find_entities.empty?
      end

      # Whether the response failed due to a timeout
      def timed_out?
        @timed_out
      end

      # Iterates over all entities in the response, using
      # automatic paging if necessary.
      # Provided for Enumerable functionality.
      # @param block [block] a block to evaluate
      # @return [OData4::Entity] each entity in turn for the query result
      def each(&block)
        unless empty?
          process_results(&block)
          unless next_page.nil?
            # ensure request gets executed with the same options
            query.execute(URI.decode next_page_url).each(&block)
          end
        end
      end

      # Returns the response body.
      def body
        response.body
      end

      # Validates the response. Throws an exception with
      # an appropriate message if a 4xx or 5xx status code
      # occured.
      #
      # @return [self]
      def validate_response!
        if error = OData4::Errors::ERROR_MAP[status]
          raise error, response, error_message
        end
      end

      private

      def execute(&block)
        @response = block.call
        logger.debug <<-EOS
          [OData4: #{service.name}] Received response:
            Headers: #{response.headers}
            Body: #{response.body}
        EOS
        check_content_type
        validate_response!
      rescue Faraday::TimeoutError
        logger.info "Request timed out."
        @timed_out = true
      end

      def logger
        service.logger
      end

      def check_content_type
        # Dynamically extend instance with methods for
        # processing the current result type
        if is_atom?
          extend OData4::Service::Response::Atom
        elsif is_json?
          extend OData4::Service::Response::JSON
        elsif is_xml?
          extend OData4::Service::Response::XML
        elsif is_plain?
          extend OData4::Service::Response::Plain
        elsif response.body.empty?
          # Some services (*cough* Microsoft *cough*) return
          # an empty response with no `Content-Type` header set.
          # We catch that here and bypass content type detection.
          @empty = true
        else
          raise RequestError, response, "Invalid response type '#{content_type}'"
        end
      end

      def entity_options
        if query
          query.entity_set.entity_options
        else
          {
            service_name: service.name,
          }
        end
      end

      def process_results(&block)
        find_entities.each do |entity_data|
          entity = parse_entity(entity_data, entity_options)
          block_given? ? block.call(entity) : yield(entity)
        end
      end
    end
  end
end
