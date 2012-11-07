module Pakyow
  class Application
    class << self
      attr_accessor :core_proc, :middleware_proc, :middlewares, :configurations

      # Sets the path to the application file so it can be reloaded later.
      #
      def inherited(subclass)
        Pakyow::Configuration::App.application_path = parse_path_from_caller(caller[0])
      end

      # Runs the application. Accepts the environment(s) to run, for example:
      # run(:development)
      # run([:development, :staging])
      #
      def run(*args)
        return if running?

        @running = true
        self.builder.run(self.prepare(args))
        detect_handler.run(builder, :Host => Pakyow::Configuration::Base.server.host, :Port => Pakyow::Configuration::Base.server.port) do |server|
          trap(:INT)  { stop(server) }
          trap(:TERM) { stop(server) }
        end
      end

      # Stages the application. Everything is loaded but the application is
      # not started. Accepts the same arguments as #run.
      #
      def stage(*args)
        return if staged?
        @staged = true
        prepare(args)
      end

      def builder
        @builder ||= Rack::Builder.new
      end

      def prepared?
        @prepared
      end

      # Returns true if the application is running.
      #
      def running?
        @running
      end

      # Returns true if the application is staged.
      #
      def staged?
        @staged
      end

      # Convenience method for base configuration class.
      #
      def config
        Pakyow::Configuration::Base
      end

      # Creates configuration for a particular environment. Example:
      # configure(:development) { app.auto_reload = true }
      #
      def configure(environment, &block)
        self.configurations ||= {}
        self.configurations[environment] = block
      end

      # The block that stores routes, handlers, and hooks.
      #
      def core(&block)
        self.core_proc = block
      end

      # The block that stores presenter related things.
      #
      def presenter(&block)
        Configuration::Base.app.presenter.proc = block
      end

      def middleware(&block)
        self.middleware_proc = block
      end
      
      def before(step, middlewares)
        middlewares = [middlewares] unless middlewares.is_a?(Array)
        step = step.to_sym

        self.middlewares ||= {}
        self.middlewares[step] ||= {}
        (self.middlewares[step][:before] ||= []).concat(middlewares)
      end
      
      def after(step, middlewares)
        middlewares = [middlewares] unless middlewares.is_a?(Array)
        step = step.to_sym

        self.middlewares ||= {}
        self.middlewares[step] ||= {}
        (self.middlewares[step][:after] ||= []).concat(middlewares)
      end

      def use(step, type, builder)
        return unless self.middlewares
        return unless self.middlewares[step]
        return unless self.middlewares[step][type]

        self.middlewares[step][type].each { |m|
          builder.use(m)
        }
      end
      

      protected

      # Prepares the application for running or staging and returns an instance
      # of the application.
      def prepare(args)
        self.load_config args.empty? || args.first.nil? ? [Configuration::Base.app.default_environment] : args
        return if prepared?

        self.builder.use(Rack::MethodOverride)

        self.builder.use(Pakyow::Middleware::Setup)

        #TODO possibly deprecate
        self.builder.instance_eval(&self.middleware_proc) if self.middleware_proc
        
        self.builder.use(Pakyow::Middleware::Static)      if Configuration::Base.app.static
        self.builder.use(Pakyow::Middleware::Logger)      if Configuration::Base.app.log
        self.builder.use(Pakyow::Middleware::Reloader)    if Configuration::Base.app.auto_reload
        
        if Configuration::Base.app.presenter
          self.use(:presentation, :before, self.builder)
          self.builder.use(Pakyow::Middleware::Presenter)   
          self.use(:presentation, :after, self.builder)
        end
        
        unless Configuration::Base.app.ignore_routes
          self.use(:routing, :before, self.builder)
          self.builder.use(Pakyow::Middleware::Router)
          self.use(:routing, :after, self.builder)
        end

        self.builder.use(Pakyow::Middleware::NotFound)    # always
        
        @prepared = true

        $:.unshift(Dir.pwd) unless $:.include? Dir.pwd
        return self.new
      end

      def load_config(args)
        if self.configurations
          args << Configuration::Base.app.default_environment if args.empty?
          args.each do |env|
            next unless config = self.configurations[env.to_sym]
            Configuration::Base.instance_eval(&config)
          end
        end
      end

      def detect_handler
        handlers = ['thin', 'mongrel', 'webrick']
        handlers.unshift(Configuration::Base.server.handler) if Configuration::Base.server.handler
        
        handlers.each do |handler|
          begin
            return Rack::Handler.get(handler)
          rescue LoadError
          rescue NameError
          end
        end
      end

      def stop(server)
        if server.respond_to?('stop!')
          server.stop!
        elsif server.respond_to?('stop')
          server.stop
        else
          # exit ungracefully if necessary...
          Process.exit!
        end
      end

      def parse_path_from_caller(caller)
        caller.match(/^(.+)(:?:\d+(:?:in `.+')?$)/)[1]
      end
    end

    include Helpers

    attr_accessor :request, :response, :presenter, :router

    def initialize
      Pakyow.app = self

      Pakyow.app.presenter = Configuration::Base.app.presenter.new if Configuration::Base.app.presenter
            
      # Load application files
      load_app(false)
    end

    # Interrupts the application and returns response immediately.
    #
    #TODO move out of app into helpers available to route logic context
    def halt!
      throw :halt, self.response
    end

    #TODO need this, but should be different (also consider renaming to #route (maybe w/o exclamation point))
    #  possible name: reroute
    #TODO move out of app into helpers available to route logic context
    def reroute!(path, method=nil)
      self.request.setup(path, method)
      @router.reroute!(self.request)
    end

    #TODO consider renaming this to #handle (maybe w/o exclamation point)
    #TODO move out of app into helpers available to route logic context
    def invoke_handler!(name_or_code)
      @router.handle!(name_or_code)
    end

    def setup_rr(env)
      self.request = Request.new(env)
      self.response = Response.new
    end

    # Called on every request.
    #
    def call(env)
      finish!
    end

    # Sends a file in the response (immediately). Accepts a File object. Mime
    # type is automatically detected.
    #
    #TODO move out of app into helpers available to route logic context
    def send_file!(source_file, send_as = nil, type = nil)
      path = source_file.is_a?(File) ? source_file.path : source_file
      send_as ||= path
      type    ||= Rack::Mime.mime_type(".#{send_as.split('.')[-1]}")

      data = ""
      File.open(path, "r").each_line { |line| data << line }

      self.response = Rack::Response.new(data, self.response.status, self.response.header.merge({ "Content-Type" => type }))
      halt!
    end

    # Sends data in the response (immediately). Accepts the data, mime type,
    # and optional file name.
    #
    #TODO move out of app into helpers available to route logic context
    def send_data!(data, type, file_name = nil)
      status = self.response ? self.response.status : 200

      headers = self.response ? self.response.header : {}
      headers = headers.merge({ "Content-Type" => type })
      headers = headers.merge({ "Content-disposition" => "attachment; filename=#{file_name}"}) if file_name

      self.response = Rack::Response.new(data, status, headers)
      halt!
    end

    # Redirects to location (immediately).
    #
    #TODO move out of app into helpers available to route logic context
    def redirect_to!(location, status_code = 302)
      headers = self.response ? self.response.header : {}
      headers = headers.merge({'Location' => location})

      self.response = Rack::Response.new('', status_code, headers)
      halt!
    end
    
    #TODO move out of app into helpers available to route logic context
    def session
      self.request.env['rack.session'] || {}
    end

    # This is NOT a useless method, it's a part of the external api
    def reload
      load_app
    end

    #TODO: handle this somewhere else since it's related to the request cycle,
    # not the application cycle (won't allow for concurrency)
    def routed?
      @router.routed?
    end

    protected

    #TODO need configuration options for cookies (plus ability to override for each?)
    def set_cookies
      if self.request.cookies && self.request.cookies != {}
        self.request.cookies.each do |key, value|
          if value.nil?
            self.response.set_cookie(key, {:path => '/', :expires => Time.now + 604800 * -1 }.merge({:value => value}))
          elsif value.is_a?(Hash)
            self.response.set_cookie(key, {:path => '/', :expires => Time.now + 604800}.merge(value))
          else
            self.response.set_cookie(key, {:path => '/', :expires => Time.now + 604800}.merge({:value => value}))
          end
        end
      end
    end

    # Reloads all application files in application_path and presenter (if specified).
    #
    def load_app(reload_app = true)
      load(Configuration::App.application_path) if reload_app

      @loader = Loader.new unless @loader
      @loader.load!(Configuration::Base.app.src_dir)

      self.load_core
      self.presenter.load if self.presenter
    end

    # Evaluates core_proc
    #
    def load_core
      @router = Router.instance

      @router.set(:default, &self.class.core_proc) if self.class.core_proc
    end
    
    # Send the response and cleanup.
    #
    #TODO remove exclamation
    def finish!
      set_cookies
      self.response.finish
    end

  end
end
