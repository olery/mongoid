# encoding: utf-8
require "support/ruby_version"

require "delegate"
require "time"
require "set"

require "active_support"
require "active_support/core_ext"
require "active_support/json"
require "active_support/inflector"
require "active_support/time_with_zone"
require "active_model"

require "mongo"

require "mongoid/version"
require "mongoid/config"
require "mongoid/persistence_context"
require "mongoid/loggable"
require "mongoid/clients"
require "mongoid/document"
require "mongoid/tasks/database"
require "mongoid/query_cache"

# If we are using Rails then we will include the Mongoid railtie. This has all
# the nifty initializers that Mongoid needs.
if defined?(Rails)
  require "mongoid/railtie"
end

# add english load path by default
I18n.load_path << File.join(File.dirname(__FILE__), "config", "locales", "en.yml")

# Ruby 3.4 compatibility patches for ActiveModel/ActiveSupport
module ActiveModel
  class Name
    def human(options = {})
      defaults = @klass.respond_to?(:i18n_scope) ? [@klass.i18n_scope, :models] : []
      defaults << options[:default] if options[:default]
      defaults << @human
      options_hash = { scope: [@klass.i18n_scope, :models], count: 1, default: defaults }.merge!(options.except(:default))
      I18n.translate(defaults.shift, **options_hash)
    end
  end

  module Translation
    def human_attribute_name(attribute, options = {})
      options   = { count: 1 }.merge!(options)
      parts     = attribute.to_s.split(".")
      attribute = parts.pop
      namespace = parts.join("/") unless parts.empty?
      attributes_scope = "#{i18n_scope}.attributes"

      if namespace
        defaults = lookup_ancestors.map { |klass| :"#{attributes_scope}.#{klass.model_name.i18n_key}/#{namespace}.#{attribute}" }
        defaults << :"#{attributes_scope}.#{namespace}.#{attribute}"
      else
        defaults = lookup_ancestors.map { |klass| :"#{attributes_scope}.#{klass.model_name.i18n_key}.#{attribute}" }
      end

      defaults << :"attributes.#{attribute}"
      defaults << options.delete(:default) if options[:default]
      defaults << attribute.humanize
      options[:default] = defaults
      I18n.translate(defaults.shift, **options)
    end
  end

  class Errors
    def generate_message(attribute, type = :invalid, options = {})
      type = options.delete(:message) if options[:message].is_a?(Symbol)

      if @base.class.respond_to?(:i18n_scope)
        i18n_scope = @base.class.i18n_scope.to_s
        defaults = @base.class.lookup_ancestors.flat_map do |klass|
          [ :"#{i18n_scope}.errors.models.#{klass.model_name.i18n_key}.attributes.#{attribute}.#{type}",
            :"#{i18n_scope}.errors.models.#{klass.model_name.i18n_key}.#{type}" ]
        end
        defaults << :"#{i18n_scope}.errors.messages.#{type}"
      else
        defaults = []
      end

      defaults << :"errors.attributes.#{attribute}.#{type}"
      defaults << :"errors.messages.#{type}"
      key = defaults.shift
      defaults = options.delete(:message) if options[:message]
      value = (attribute != :base ? @base.send(:read_attribute_for_validation, attribute) : nil)

      options = {
        default: defaults,
        model: @base.model_name.human,
        attribute: @base.class.human_attribute_name(attribute),
        value: value,
        object: @base
      }.merge!(options)
      I18n.translate(key, **options)
    end
  end
end

# Fix ActiveSupport::Cache::Entry.new for positional hash arguments
module ActiveSupport
  module Cache
    class Entry
      class << self
        alias_method :new_without_fix, :new
        def new(value, *args, **kwargs)
          if args.length == 1 && args[0].is_a?(Hash) && kwargs.empty?
            new_without_fix(value, **args[0])
          else
            new_without_fix(value, *args, **kwargs)
          end
        end
      end
    end
  end
end

module Mongoid
  extend Loggable
  extend self

  # A string added to the platform details of Ruby driver client handshake documents.
  #
  # @since 6.1.0
  PLATFORM_DETAILS = "mongoid-#{VERSION}".freeze

  # The minimum MongoDB version supported.
  MONGODB_VERSION = "2.4.0"

  # Sets the Mongoid configuration options. Best used by passing a block.
  #
  # @example Set up configuration options.
  #   Mongoid.configure do |config|
  #     config.connect_to("mongoid_test")
  #   end
  #
  # @return [ Config ] The configuration object.
  #
  # @since 1.0.0
  def configure
    block_given? ? yield(Config) : Config
  end

  # Convenience method for getting the default client.
  #
  # @example Get the default client.
  #   Mongoid.default_client
  #
  # @return [ Mongo::Client ] The default client.
  #
  # @since 5.0.0
  def default_client
    Clients.default
  end

  # Disconnect all active clients.
  #
  # @example Disconnect all active clients.
  #   Mongoid.disconnect_clients
  #
  # @return [ true ] True.
  #
  # @since 5.0.0
  def disconnect_clients
    Clients.disconnect
  end

  # Convenience method for getting a named client.
  #
  # @example Get a named client.
  #   Mongoid.client(:default)
  #
  # @return [ Mongo::Client ] The named client.
  #
  # @since 5.0.0
  def client(name)
    Clients.with_name(name)
  end

  # Take all the public instance methods from the Config singleton and allow
  # them to be accessed through the Mongoid module directly.
  #
  # @example Delegate the configuration methods.
  #   Mongoid.database = Mongo::Connection.new.db("test")
  #
  # @since 1.0.0
  CONFIG_DELEGATED_METHODS = Config.public_instance_methods(false) - [ :logger=, :logger ]

  CONFIG_DELEGATED_METHODS.each do |method_name|
    define_singleton_method(method_name) do |*args, **kwargs, &block|
      Config.public_send(method_name, *args, **kwargs, &block)
    end
  end

  private_constant :CONFIG_DELEGATED_METHODS
end
