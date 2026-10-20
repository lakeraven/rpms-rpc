# frozen_string_literal: true

module RpmsRpc
  # The declared resource, verb and path of a public API method (rpms-rpc#389).
  # A declaration names the shape a host's HTTP facade would expose. It does not
  # send an RPC, and it does not change a mapping or the wire.
  #
  # Verbs are GET, PUT, POST and DELETE. resource is a non-blank String with no
  # leading or trailing whitespace. path is a canonical absolute path: a String
  # starting with "/", "/" alone allowed; otherwise no trailing "/", every
  # segment non-empty and neither "." nor "..", and no whitespace, "?" or "#".
  # resource and path are stored as frozen copies, so changing the caller's
  # string later does not change the declaration. The method must be public and
  # defined by the module itself: a public singleton method, or a public
  # instance method when the module extends itself. Inherited methods and
  # private methods are refused. Declaring the same method again with a
  # different shape raises ArgumentError; an identical declaration (same values)
  # is left as it is.
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
        raise ArgumentError, "resource must be a non-blank String with no leading or trailing whitespace (got #{resource.inspect})" unless valid_resource?(resource)
        raise ArgumentError, "path must be a canonical absolute path (got #{path.inspect})" unless valid_path?(path)

        name = method.to_sym
        raise ArgumentError, "#{mod} does not define #{name}" unless defines?(mod, name)

        # Copies, not the caller's objects: a later mutation of those strings
        # must not change the stored shape. Equality stays by value, so an
        # identical redeclare still matches.
        shape = { resource: String.new(resource).freeze, verb: String.new(verb).freeze, path: String.new(path).freeze }.freeze
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

      # Non-blank, and no leading or trailing whitespace (a stripped copy would differ).
      def valid_resource?(value)
        value.is_a?(String) && !value.empty? && value == value.strip
      end

      # "/" is a path. Every other path starts with "/", does not end with "/",
      # has no empty, "." or ".." segment, and contains no whitespace, "?" or "#".
      def valid_path?(path)
        return false unless path.is_a?(String) && path.start_with?("/") && !path.match?(/[\s?#]/)
        return true if path == "/"
        return false if path.end_with?("/")

        path.split("/", -1).drop(1).none? { |segment| segment.empty? || segment == "." || segment == ".." }
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
