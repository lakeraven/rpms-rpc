# frozen_string_literal: true

module RpmsRpc
  # The declared resource, verb and path of a public API method (rpms-rpc#389).
  # A declaration names the shape a host's HTTP facade would expose. It does not
  # send an RPC, and it does not change a mapping or the wire.
  #
  # Verbs are GET, PUT, POST and DELETE. Declaring a method the module does not
  # define raises ArgumentError.
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

        name = method.to_sym
        raise ArgumentError, "#{mod} does not define #{name}" unless defines?(mod, name)

        declarations[[ mod, name ].freeze] = { resource: resource, verb: verb, path: path }.freeze
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

      # Singleton methods (def self.x, extend self) and instance methods.
      def defines?(mod, name)
        mod.method(name)
        true
      rescue NameError
        mod.instance_methods(true).include?(name) || mod.private_instance_methods(true).include?(name)
      end
    end
  end
end
