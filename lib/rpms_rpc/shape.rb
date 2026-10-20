# frozen_string_literal: true

module RpmsRpc
  # The declared resource, verb and path of a public API method (rpms-rpc#389).
  # A declaration names the shape a host's HTTP facade would expose. It does not
  # send an RPC, and it does not change a mapping or the wire.
  #
  # Verbs are GET, PUT, POST and DELETE. resource is a non-blank String. path is
  # a String starting with "/" and not ending with "/" (the root path "/" is
  # allowed). The method must be public and defined by the module itself: a
  # public singleton method, or a public instance method when the module extends
  # itself. Inherited methods and private methods are refused. Declaring the
  # same method again with a different shape raises ArgumentError; an identical
  # declaration is left as it is.
  module Shape
    VERBS = %w[GET PUT POST DELETE].freeze

    # Mixed into an API module so the declaration sits beside the def:
    #   shape :for_patient, resource: "vitals", verb: "GET", path: "/patients/{dfn}/vitals"
    module Declarable
      def shape(method, resource:, verb:, path:)
        Shape.declare(self, method, resource: resource, verb: verb, path: path)
      end
    end

    class << self
      def declare(mod, method, resource:, verb:, path:)
        verb = verb.to_s
        raise ArgumentError, "verb must be one of #{VERBS.join(', ')} (got #{verb.inspect})" unless VERBS.include?(verb)
        raise ArgumentError, "resource must be a non-blank String (got #{resource.inspect})" unless non_blank_string?(resource)
        raise ArgumentError, "path must be a String starting with / and not ending with / (got #{path.inspect})" unless valid_path?(path)

        name = method.to_sym
        raise ArgumentError, "#{mod} does not define #{name}" unless defines?(mod, name)

        shape = { resource: resource, verb: verb, path: path }.freeze
        key = [ mod, name ].freeze
        existing = declarations[key]
        return existing if existing == shape
        raise ArgumentError, "#{mod}.#{name} is already declared with a different shape" if existing

        declarations[key] = shape
      end

      def for(mod, method)
        declarations[[ mod, method.to_sym ]]
      end

      # { [module, method_name] => { resource:, verb:, path: } } for every declaration.
      def all
        declarations.dup
      end

      private

      def declarations
        @declarations ||= {}
      end

      def non_blank_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      # "/" is a path. Every other path starts with "/" and does not end with "/".
      def valid_path?(path)
        path.is_a?(String) && path.start_with?("/") && (path == "/" || !path.end_with?("/"))
      end

      # A public method defined on mod, not inherited. `extend self` publishes
      # the module's own public instance methods; Shape::Declarable (shape)
      # and private helpers stay out.
      def defines?(mod, name)
        return true if mod.singleton_class.public_method_defined?(name, false)
        return false unless extends_self?(mod)

        mod.public_method_defined?(name, false)
      end

      def extends_self?(mod)
        mod.singleton_class.included_modules.include?(mod)
      end
    end
  end
end
