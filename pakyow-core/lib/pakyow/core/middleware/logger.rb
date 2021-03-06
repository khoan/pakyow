require 'pakyow/core/app'
require 'pakyow/core/logger/request_logger'

module Pakyow
  module Middleware
    # Rack middleware used for logging during the request / response lifecycle.
    #
    # @api private
    class Logger
      Pakyow::App.middleware do |builder|
        builder.use Pakyow::Middleware::Logger
      end

      Pakyow::CallContext.after :error do
        logger.houston(req.error)
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        logger = Pakyow::Logger::RequestLogger.new(:http)
        env['rack.logger'] = logger

        logger.prologue(env)
        result = @app.call(env)
        logger.epilogue(result)

        result
      end
    end
  end
end
