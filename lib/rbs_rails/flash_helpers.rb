module RbsRails
  # Generates RBS for Rails flash accessor methods — `notice`, `alert`, and any
  # custom types registered via `ActionController::Flash.add_flash_types`.
  #
  # These methods are added dynamically at boot: `add_flash_types` defines the
  # method on the controller AND registers it as a `helper_method`, so they are
  # callable both in controllers and in views. Rather than guessing statically,
  # we reflect on `_flash_types` (the class_attribute it populates) to get the
  # real set, emit them as an interface, and mix it into `ActionController::Base`
  # so every controller inherits them.
  #
  # The view side is owned by whoever models the view context — rbs_infer's
  # `ActionViewContext` includes this interface, mirroring how it already
  # includes `_RbsRailsPathHelpers`.
  class FlashHelpers
    def self.generate
      # Populate `descendants` so app/engine controllers that call
      # `add_flash_types` are visible.
      Rails.application.eager_load!

      new(flash_types: collect_flash_types).generate
    end

    # The union of flash types across `ActionController::Base` and its
    # descendants: the framework defaults (`:notice`, `:alert`) plus any types
    # the app or its engines registered via `add_flash_types`. Sorted for a
    # stable signature.
    def self.collect_flash_types
      base = ::ActionController::Base
      ([base] + base.descendants)
        .flat_map { |controller| controller.respond_to?(:_flash_types) ? controller._flash_types : [] }
        .uniq
        .sort
    end

    # @rbs flash_types: Array[Symbol]
    def initialize(flash_types:)
      @flash_types = flash_types
    end

    def generate
      # `flash[type]` is nil when the key is unset, so each accessor is nilable.
      methods = flash_types.map { |type| "def #{type}: () -> ::String?" }

      <<~RBS
        # resolve-type-names: false

        interface ::_RbsRailsFlashHelpers
        #{methods.join("\n").indent(2)}
        end

        module ::ActionController
          class ::ActionController::Base
            include ::_RbsRailsFlashHelpers
          end
        end
      RBS
    end

    private

    # @dynamic flash_types
    attr_reader :flash_types
  end
end
