module RbsRails
  module ActiveRecord

    # @rbs klass: untyped
    def self.generatable?(klass) #: boolish
      return false if klass.abstract_class?

      klass.connection.table_exists?(klass.table_name)
    end

    # @rbs klass: untyped
    # @rbs dependencies: Array[String]
    def self.class_to_rbs(klass) #: untyped
      Generator.new(klass).generate
    end

    class Generator
      IGNORED_ENUM_KEYS = %i[_prefix _suffix _default _scopes] #: Array[Symbol]

      # @rbs @parse_model_file: nil | Parser::AST::Node
      # @rbs @enum_definitions: Array[Hash[Symbol, untyped]]
      # @rbs @klass_name: String

      attr_reader :dependencies #: DependencyBuilder

      # @rbs klass: singleton(ActiveRecord::Base) & Enum & Scope
      def initialize(klass) #: untyped
        @klass = klass
        @dependencies = DependencyBuilder.new
        @klass_name = Util.module_name(klass, abs: false)

        namespaces = klass_name(abs: false).split('::').tap{ |names| names.pop }
        @dependencies << namespaces.join('::') unless namespaces.empty?
      end

      def generate #: String
        Util.format_rbs klass_decl
      end

      private def klass_decl #: String
        <<~RBS
          # resolve-type-names: false

          #{header}
            extend ::ActiveRecord::Base::ClassMethods[#{klass_name}, #{relation_class_name}, #{pk_type}#{validated_model_arg}]

          #{columns}
          #{alias_columns}
          #{associations}
          #{generated_association_methods}
          #{has_secure_password}
          #{delegated_type_instance}
          #{delegated_type_scope(singleton: true)}
          #{enum_instance_methods}
          #{enum_class_methods(singleton: true)}
          #{scopes(singleton: true)}

          #{generated_relation_methods_decl}

          #{relation_decl}

          #{collection_proxy_decl}

          #{validated_marker}

          #{conditional_presence_markers}

          #{through_derived_markers}

          #{footer}

          #{dependencies.build}
        RBS
      end

      private def pk_type #: String
        pk = klass.primary_key
        return 'top' unless pk

        case klass.primary_key
        when Array
          types = klass.columns
                       .select { |column| klass.primary_key.include?(column.name) }
                       .map { |pk| sql_type_to_class(pk.type) }
          "[#{types.join(' , ')}]"
        else
          col = klass.columns.find { |column| column.name == pk }
          sql_type_to_class(col.type)
        end
      end

      private def generated_relation_methods_decl #: String
        <<~RBS
          module #{generated_relation_methods_name}
            #{enum_class_methods(singleton: false)}
            #{scopes(singleton: false)}
            #{delegated_type_scope(singleton: false)}
          end
        RBS
      end

      private def relation_decl #: String
        <<~RBS
          class #{relation_class_name} < ::ActiveRecord::Relation
            include ::Enumerable[#{klass_name}]
            include #{generated_relation_methods_name}
            include ::ActiveRecord::Relation::Methods[#{klass_name}, #{pk_type}#{validated_model_arg}]
          end
        RBS
      end

      private def collection_proxy_decl #: String
        <<~RBS
          class #{klass_name}::ActiveRecord_Associations_CollectionProxy < ::ActiveRecord::Associations::CollectionProxy
            include ::Enumerable[#{klass_name}]
            include #{generated_relation_methods_name}
            include ::ActiveRecord::Relation::Methods[#{klass_name}, #{pk_type}#{validated_model_arg}]

            def build: (?::ActiveRecord::Associations::CollectionProxy::_EachPair attributes) ?{ () -> untyped } -> #{klass_name}
                     | (::Array[::ActiveRecord::Associations::CollectionProxy::_EachPair] attributes) ?{ () -> untyped } -> ::Array[#{klass_name}]
            def create: (?::ActiveRecord::Associations::CollectionProxy::_EachPair attributes) ?{ () -> untyped } -> #{klass_name}
                      | (::Array[::ActiveRecord::Associations::CollectionProxy::_EachPair] attributes) ?{ () -> untyped } -> ::Array[#{klass_name}]
            def create!: (?::ActiveRecord::Associations::CollectionProxy::_EachPair attributes) ?{ () -> untyped } -> #{klass_name}
                       | (::Array[::ActiveRecord::Associations::CollectionProxy::_EachPair] attributes) ?{ () -> untyped } -> ::Array[#{klass_name}]
            def reload: () -> ::Array[#{klass_name}]

            def replace: (::Array[#{klass_name}]) -> void
            def delete: (*#{klass_name} | #{pk_type}) -> ::Array[#{klass_name}]
            def destroy: (*#{klass_name} | #{pk_type}) -> ::Array[#{klass_name}]
            def <<: (*#{klass_name} | ::Array[#{klass_name}]) -> self
            def prepend: (*#{klass_name} | ::Array[#{klass_name}]) -> self
          end
        RBS
      end

      private def header #: String
        namespace = +''
        klass_name(abs: false).split('::').map do |mod_name|
          namespace += "::#{mod_name}"
          mod_object = Object.const_get(namespace)
          case mod_object
          when Class
            # @type var superclass: Class
            superclass = _ = mod_object.superclass
            superclass_name = Util.module_name(superclass, abs: false)
            @dependencies << superclass_name

            "class #{namespace} < ::#{superclass_name}"
          when Module
            "module #{namespace}"
          else
            raise 'unreachable'
          end
        end.join("\n")
      end

      private def footer #: String
        "end\n" * klass_name(abs: false).split('::').size
      end

      private def associations #: String
        [
          has_many,
          has_and_belongs_to_many,
          has_one,
          belongs_to,
        ].join("\n")
      end

      private def has_many #: String
        klass.reflect_on_all_associations(:has_many).map do |a|
          @dependencies << a.klass.name

          singular_name = a.name.to_s.singularize
          type = Util.module_name(a.klass)
          collection_type = "#{type}::ActiveRecord_Associations_CollectionProxy"
          @dependencies << collection_type

          <<~RUBY.chomp
            def #{a.name}: () -> #{collection_type}
            def #{a.name}=: (#{collection_type} | ::Array[#{type}]) -> (#{collection_type} | ::Array[#{type}])
            def #{singular_name}_ids: () -> ::Array[::Integer]
            def #{singular_name}_ids=: (::Array[::Integer]) -> ::Array[::Integer]
          RUBY
        end.join("\n")
      end

      private def has_and_belongs_to_many #: String
        klass.reflect_on_all_associations(:has_and_belongs_to_many).map do |a|
          @dependencies << a.klass.name

          singular_name = a.name.to_s.singularize
          type = Util.module_name(a.klass)
          collection_type = "#{type}::ActiveRecord_Associations_CollectionProxy"
          @dependencies << collection_type

          <<~RUBY.chomp
            def #{a.name}: () -> #{collection_type}
            def #{a.name}=: (#{collection_type} | ::Array[#{type}]) -> (#{collection_type} | ::Array[#{type}])
            def #{singular_name}_ids: () -> ::Array[::Integer]
            def #{singular_name}_ids=: (::Array[::Integer]) -> ::Array[::Integer]
          RUBY
        end.join("\n")
      end

      private def has_one #: String
        klass.reflect_on_all_associations(:has_one).map do |a|
          @dependencies << a.klass.name unless a.polymorphic?

          type = a.polymorphic? ? 'untyped' : Util.module_name(a.klass)
          type_optional = optional(type)
          <<~RUBY.chomp
            def #{a.name}: () -> #{type_optional}
            def #{a.name}=: (#{type_optional}) -> #{type_optional}
            def build_#{a.name}: (?untyped) -> #{type}
            def create_#{a.name}: (?untyped) -> #{type}
            def create_#{a.name}!: (?untyped) -> #{type}
            def reload_#{a.name}: () -> #{type_optional}
          RUBY
        end.join("\n")
      end

      private def belongs_to #: String
        klass.reflect_on_all_associations(:belongs_to).map do |a|
          @dependencies << a.klass.name unless a.polymorphic?

          type = a.polymorphic? ? 'untyped' : Util.module_name(a.klass)
          type_optional = optional(type)
          # Always emit the nilable form on the model. `belongs_to` (non-
          # optional) implicitly registers a `presence: true` validator, which
          # the `Validated` marker picks up and narrows back to `Foo` —
          # matching the lifecycle reality that a new record may not yet have
          # the association set.
          # @type var methods: Array[String]
          methods = []
          methods << "def #{a.name}: () -> #{type_optional}"
          methods << "def #{a.name}=: (#{type_optional}) -> #{type_optional}"
          methods << "def reload_#{a.name}: () -> #{type_optional}"
          if !a.polymorphic?
            methods << "def build_#{a.name}: (untyped) -> #{type}"
            methods << "def create_#{a.name}: (untyped) -> #{type}"
            methods << "def create_#{a.name}!: (untyped) -> #{type}"
          end
          methods.join("\n")
        end.join("\n")
      end

      # Emits one marker class per conditional `validates :*, presence: true`
      # (keyed by the `if:`/`unless:` predicate). Markers are intended to be
      # composed by intersection with the model type — `OrderImport &
      # OrderImport::ValidatedAsShipment` — once a Steep extension wires
      # boolean predicates to a postcondition refinement (see
      # felixefelip/steep, postcondition refinement issue).
      private def conditional_presence_markers #: String
        conditional_presence_groups.filter_map do |(kind, predicate), attrs|
          methods = narrowed_method_decls(attrs)
          next if methods.empty?

          marker = conditional_presence_marker_name(kind, predicate)
          <<~RBS.chomp
            class #{klass_name}::#{marker}
              #{methods.join("\n  ")}
            end
          RBS
        end.join("\n\n")
      end

      # Emits the `Validated` marker class with non-nilable getters for every
      # attribute that AR guarantees on a persisted+validated record:
      #
      # 1. `id` (when the column exists) — assigned on insert.
      # 2. Attributes covered by an *unconditional* `validates :*, presence: true`.
      # 3. `created_at` / `updated_at` (when columns exist) — set automatically.
      #
      # Composed by intersection at finder return types (`Model &
      # Model::Validated`) and on `update`/`save`/`valid?` truthy branches
      # (issue felixefelip/steep, conditional postconditions).
      private def validated_marker #: String
        methods = narrowed_method_decls(validated_marker_attrs)
        return "" if methods.empty?

        <<~RBS.chomp
          class #{klass_name}::Validated
            #{methods.join("\n  ")}
          end
        RBS
      end

      # When the model has a `Validated` marker, pass it as the
      # `ValidatedModel` type parameter to `Relation::Methods`,
      # `Base::ClassMethods`, etc., so finders like `find`, `find_by!`,
      # `first!`, `where.first`, …, return `Model & Model::Validated`.
      # See the matching `ValidatedModel = Model` default in the
      # gem_rbs_collection activerecord overrides.
      private def validated_model_arg #: String
        return "" if narrowed_method_decls(validated_marker_attrs).empty?

        ", #{klass_name}::Validated"
      end

      # The attribute list that populates `Validated`. Order matters only
      # for stable snapshot diffs: id first, then validated attrs, then
      # timestamps last.
      private def validated_marker_attrs #: Array[Symbol]
        attrs = [] #: Array[Symbol]
        attrs << :id if klass.columns.any? { |c| c.name == "id" }
        attrs.concat(unconditional_presence_attrs)
        %w[created_at updated_at].each do |ts|
          attrs << ts.to_sym if klass.columns.any? { |c| c.name == ts }
        end
        attrs.uniq
      end

      # Returns the YAML-ready postcondition entries for this model. Each
      # entry maps a method call (whose receiver is the model) to a `self`
      # refinement to apply on the truthy/falsy branch. See
      # `.steep_postconditions.yml` consumed by Steep.
      #
      # Returned as an Array of Hashes with string keys so the CLI can YAML.dump
      # them without symbol-prefix noise.
      def postcondition_entries #: Array[Hash[String, untyped]]
        entries = [] #: Array[Hash[String, untyped]]
        short_name = klass_name(abs: false)

        marker_descriptors.each do |descriptor|
          target = "#{short_name} & #{short_name}::#{descriptor[:name]}"
          drop_name = "#{short_name}::#{descriptor[:name]}"

          descriptor[:triggers].each do |trigger|
            method, branch, action = trigger
            action ||= :self # backward compat for 2-element triggers

            body =
              case action
              when :drops
                { "drops" => [drop_name] }
              else
                { "self" => target }
              end

            entries << {
              "class" => short_name,
              "method" => method,
              branch => body,
            }
          end
        end

        entries.concat(through_postcondition_entries)

        entries
      end

      # Enumerates the marker classes this model contributes a postcondition
      # for, with the narrowable attrs each marker covers and the
      # (method, branch) pairs that should refine to it. Used both by
      # `postcondition_entries` locally and by *host* generators that derive
      # markers through `has_one :x, through: :y` associations (issue #2).
      #
      # The `Validated` descriptor is only included when there is at least
      # one *unconditional* presence validator with a narrowable attr —
      # id-only / timestamps-only models still get the RBS marker class but
      # no postcondition entries, mirroring pre-existing behavior.
      def marker_descriptors #: Array[Hash[Symbol, untyped]]
        descriptors = [] #: Array[Hash[Symbol, untyped]]

        if !narrowed_method_decls(unconditional_presence_attrs).empty?
          # `when_true.self` for every validated method (intersection narrows
          # to `Model & Validated`). For the subset that returns false on
          # failure (`save`, `update`, `valid?`), also emit `when_false.drops`
          # so the marker is removed in the else branch — see
          # felixefelip/steep#29 (intersection alone can't drop a marker).
          self_triggers = VALIDATED_POSTCONDITION_METHODS.map { |m| [m, "when_true", :self] }
          drop_triggers = DROPS_POSTCONDITION_METHODS.map { |m| [m, "when_false", :drops] }

          descriptors << {
            name: "Validated",
            attrs: validated_marker_attrs,
            triggers: self_triggers + drop_triggers,
          }
        end

        conditional_presence_groups.each do |(kind, predicate), attrs|
          next if narrowed_method_decls(attrs).empty?

          marker = conditional_presence_marker_name(kind, predicate)
          branch = kind == :if ? "when_true" : "when_false"
          descriptors << {
            name: marker,
            attrs: attrs.uniq,
            triggers: [[predicate.to_s, branch, :self]],
          }
        end

        descriptors
      end

      # Same lookup as the private `narrow_type_for`, exposed publicly so a
      # *host* generator can ask a *target* generator what type a given attr
      # narrows to in this model's markers.
      # @rbs attr_name: Symbol
      def narrowed_type_for(attr_name) #: String?
        narrow_type_for(attr_name)
      end

      # AR / AM methods that succeed only when all validations pass. Truthy
      # return ⇒ the receiver is freshly validated, so `self` refines to
      # `Model & Model::Validated`.
      VALIDATED_POSTCONDITION_METHODS = %w[valid? save save! update update!]

      # Subset of `VALIDATED_POSTCONDITION_METHODS` that has a meaningful
      # *false* return — i.e., predicates that signal failure by
      # returning false rather than raising. `save!` / `update!` are
      # excluded because they raise on failure (no falsy path).
      #
      # For these methods, when the call returns false we emit
      # `when_false: { drops: ["Model::Validated"] }` so Steep removes
      # the `Validated` marker from the receiver in the else branch
      # (felixefelip/steep#29). Intersection alone in `when_false.self`
      # couldn't drop a marker; `drops:` does it explicitly.
      DROPS_POSTCONDITION_METHODS = %w[valid? save update]

      # @rbs attrs: Array[Symbol]
      private def narrowed_method_decls(attrs) #: Array[String]
        attrs.uniq.filter_map do |attr|
          narrowed = narrow_type_for(attr)
          narrowed && "def #{attr}: () -> #{narrowed}"
        end
      end

      private def conditional_presence_groups #: Hash[[Symbol, Symbol], Array[Symbol]]
        # @type var groups: Hash[[Symbol, Symbol], Array[Symbol]]
        groups = {}

        klass.validators.each do |validator|
          next unless validator.is_a?(::ActiveModel::Validations::PresenceValidator)

          key = conditional_presence_key(validator)
          next unless key

          (groups[key] ||= []).concat(validator.attributes)
        end

        groups
      end

      private def unconditional_presence_attrs #: Array[Symbol]
        attrs = [] #: Array[Symbol]

        # Rails registers a `PresenceValidator` with an internal `if:` lambda
        # for every non-optional `belongs_to` (see Rails'
        # `active_record/associations/builder/belongs_to.rb`). The lambda is
        # an implementation detail, not a user-supplied condition, so the
        # validator looks "conditional" to the loop below and would be
        # skipped. Pre-include those associations directly.
        klass.reflect_on_all_associations(:belongs_to).each do |a|
          next if a.options[:optional]
          next if a.polymorphic?
          attrs << a.name
        end

        klass.validators.each do |validator|
          next unless validator.is_a?(::ActiveModel::Validations::PresenceValidator)
          next if validator.options[:if] || validator.options[:unless]

          attrs.concat(validator.attributes)
        end

        attrs.uniq
      end

      private def conditional_presence_key(validator) #: [Symbol, Symbol]?
        if (m = validator.options[:if]).is_a?(Symbol)
          [:if, m]
        elsif (m = validator.options[:unless]).is_a?(Symbol)
          [:unless, m]
        end
      end

      private def conditional_presence_marker_name(kind, predicate) #: String
        base = predicate.to_s.chomp("?")
        camelized = base.split("_").map(&:capitalize).join
        prefix = kind == :if ? "ValidatedAs" : "ValidatedUnless"
        "#{prefix}#{camelized}"
      end

      # ---------------------------------------------------------------------
      # Through-derived markers (issue felixefelip/rbs_rails#2)
      #
      # When this model is a *host* with `has_one :x, through: :y`, and the
      # *target* of `:y` carries a marker that narrows `:x`, mirror that
      # marker on this model so a Steep `via_receiver` postcondition
      # (felixefelip/steep#14) can refine the host as a side effect of
      # narrowing the target.
      #
      # Example: `Order has_one :logistics_operator, through: :order_import`,
      # and `OrderImport::ValidatedAsShipment` declares
      # `logistics_operator: ::Company`. We emit
      # `Order::ValidatedAsShipmentViaOrderImport` with the same narrowed
      # decl, plus a sidecar entry that adds a `via_receiver` under
      # `OrderImport#shipment?`'s `when_true`.
      # ---------------------------------------------------------------------

      # Returns the RBS for derived marker classes that this host model
      # contributes, grouped so all attrs that share a (target marker,
      # through assoc) pair land in the same Via* class.
      private def through_derived_markers #: String
        groups = through_derived_groups
        return "" if groups.empty?

        groups.map do |(_target_short, _marker_name, _via_assoc), info|
          methods = info[:methods].values.join("\n  ")
          <<~RBS.chomp
            class #{klass_name}::#{info[:derived_name]}
              #{methods}
            end
          RBS
        end.join("\n\n")
      end

      # Sidecar entries this host contributes for `via_receiver` refinement.
      # Each entry is keyed by the *target's* class/method; the CLI merges
      # these with the target's own `self:` entry.
      def through_postcondition_entries #: Array[Hash[String, untyped]]
        groups = through_derived_groups
        return [] if groups.empty?

        host_short = klass_name(abs: false)
        entries = [] #: Array[Hash[String, untyped]]

        groups.each do |(target_short, _marker_name, via_assoc), info|
          via = {
            "through" => "#{host_short}##{via_assoc}",
            "as" => "#{host_short} & #{host_short}::#{info[:derived_name]}",
          }
          info[:triggers].each do |trigger|
            method, branch, action = trigger
            # `via_receiver` is an intersection-only mechanism (the
            # host's association type narrows when the inner predicate
            # fires). It doesn't compose with `drops:` (which is
            # subtraction on the *inner* type) — so we skip the drop
            # triggers when emitting through-derived entries. The
            # target's own generator already emits the `drops:` for
            # the inner type.
            next if action == :drops

            entries << {
              "class" => target_short,
              "method" => method,
              branch => { "via_receiver" => [via] },
            }
          end
        end

        entries
      end

      # Walks each qualifying through association and resolves the target's
      # markers exactly once. Returns a hash keyed by
      # [target_short_name, target_marker_name, through_assoc_name] with the
      # per-derived-marker payload (derived class name, narrowed method
      # decls, list of (method, branch) triggers). Memoized — both
      # `through_derived_markers` and `through_postcondition_entries`
      # consume it.
      private def through_derived_groups #: Hash[Array[untyped], Hash[Symbol, untyped]]
        return @through_derived_groups if defined?(@through_derived_groups)

        groups = {} #: Hash[Array[untyped], Hash[Symbol, untyped]]
        target_generators = {} #: Hash[Class, Generator]

        through_associations.each do |refl|
          target = refl.through_reflection&.klass
          next unless target

          source_attr = refl.source_reflection&.name
          next unless source_attr

          target_gen = target_generators[target] ||= Generator.new(target)
          final_type = target_gen.narrowed_type_for(source_attr)
          next unless final_type

          via_assoc = refl.through_reflection.name
          target_short = Util.module_name(target, abs: false)

          target_gen.marker_descriptors.each do |descriptor|
            next unless descriptor[:attrs].include?(source_attr)

            key = [target_short, descriptor[:name], via_assoc]
            info = groups[key] ||= {
              derived_name: derived_marker_name(descriptor[:name], via_assoc),
              methods: {},
              triggers: descriptor[:triggers],
            }
            info[:methods][refl.name] ||= "def #{refl.name}: () -> #{final_type}"
          end
        end

        @through_derived_groups = groups
      end

      # Returns the `has_one :x, through: :y` reflections on this model that
      # qualify for derived-marker emission. Skips:
      # - `has_many through:` (the receiver is a collection, not a single
      #   target — there is no useful `via_receiver` chain through it);
      # - polymorphic through reflections (target type undecided);
      # - nested through (`:y` itself is `through:` something else —
      #   Phase 3+ in the Steep narrowing).
      private def through_associations #: Array[untyped]
        klass.reflect_on_all_associations(:has_one).select do |a|
          next false unless a.options[:through]
          tr = a.through_reflection
          next false unless tr
          next false if tr.polymorphic?
          next false if tr.options[:through]
          true
        end
      end

      # @rbs target_marker_name: String
      # @rbs via_assoc: Symbol
      private def derived_marker_name(target_marker_name, via_assoc) #: String
        camelized = via_assoc.to_s.split("_").map(&:capitalize).join
        "#{target_marker_name}Via#{camelized}"
      end

      private def narrow_type_for(attr_name) #: String?
        if (assoc = klass.reflect_on_association(attr_name)) && assoc.macro == :belongs_to
          return nil if assoc.polymorphic?
          @dependencies << assoc.klass.name
          return Util.module_name(assoc.klass)
        end

        col = klass.columns.find { |c| c.name == attr_name.to_s }
        return nil unless col

        sql_type_to_class(col.type)
      end

      private def generated_association_methods #: String
        # @type var sigs: Array[String]
        sigs = []

        # Needs to require "active_storage/engine"
        if klass.respond_to?(:attachment_reflections)
          sigs << "module #{klass_name}::GeneratedAssociationMethods"
          sigs << klass.attachment_reflections.map do |name, reflection|
            case reflection.macro
            when :has_one_attached
              <<~EOS
                def #{name}: () -> ::ActiveStorage::Attached::One
                def #{name}=: (::ActionDispatch::Http::UploadedFile) -> ::ActionDispatch::Http::UploadedFile
                            | (::Rack::Test::UploadedFile) -> ::Rack::Test::UploadedFile
                            | (::ActiveStorage::Blob) -> ::ActiveStorage::Blob
                            | (::String) -> ::String
                            | ({ io: ::IO, filename: ::String, content_type: ::String? }) -> { io: ::IO, filename: ::String, content_type: ::String? }
                            | (nil) -> nil
              EOS
            when :has_many_attached
              <<~EOS
                def #{name}: () -> ::ActiveStorage::Attached::Many
                def #{name}=: (untyped) -> untyped
              EOS
            else
              raise "unknown macro: #{reflection.macro}"
            end
          end.join("\n")
          sigs << "end"
          sigs << "include #{klass_name}::GeneratedAssociationMethods"
        end

        sigs.join("\n")
      end

      # @rbs singleton: bool
      private def delegated_type_scope(singleton:) #: String
        definitions = delegated_type_definitions
        return "" unless definitions
        definitions.map do |definition|
          definition[:types].map do |type|
            scope_name = type.tableize.gsub("/", "_")
            "def #{singleton ? 'self.' : ''}#{scope_name}: () -> #{relation_class_name}"
          end
        end.flatten.join("\n")
      end

      private def delegated_type_instance #: String
        definitions = delegated_type_definitions
        return "" unless definitions
        # @type var methods: Array[String]
        methods = []
        definitions.each do |definition|
          methods << "def #{definition[:role]}_class: () -> ::Class"
          methods << "def #{definition[:role]}_name: () -> ::String"
          methods << definition[:types].map do |type|
            scope_name = type.tableize.gsub("/", "_")
            singular = scope_name.singularize
            <<~RUBY.chomp
              def #{singular}?: () -> bool
              def #{singular}: () -> #{type.classify}?
              def #{singular}_id: () -> Integer?
            RUBY
          end.join("\n")
        end
        methods.join("\n")
      end

      private def delegated_type_definitions #: Array[{ role: Symbol, types: Array[String] }]?
        ast = parse_model_file
        return unless ast

        traverse(ast).map do |node|
          # @type block: { role: Symbol, types: Array[String] }?
          next unless node.type == :send
          next unless node.children[0].nil?
          next unless node.children[1] == :delegated_type

          role_node = node.children[2]
          next unless role_node
          next unless role_node.type == :sym
          # @type var role: Symbol
          role = role_node.children[0]

          args_node = node.children[3]
          next unless args_node
          next unless args_node.type == :hash

          types = traverse(args_node).map do |n|
            # @type block: Array[String]?
            next unless n.type == :pair
            key_node = n.children[0]
            next unless key_node
            next unless key_node.type == :sym
            next unless key_node.children[0] == :types

            types_node = n.children[1]
            next unless types_node
            next unless types_node.type == :array
            code = types_node.loc.expression.source
            eval(code)
          end.compact.flatten

          { role: role, types: types }
        end.compact
      end

      private def has_secure_password #: String?
        ast = parse_model_file
        return unless ast

        traverse(ast).map do |node|
          # @type block: String?
          next unless node.type == :send
          next unless node.children[0].nil?
          next unless node.children[1] == :has_secure_password

          attribute_node = node.children[2]
          attribute = if attribute_node && attribute_node.type == :sym
                        attribute_node.children[0]
                      else
                        :password
                      end

          <<~EOS
            module #{klass_name}::ActiveModel_SecurePassword_InstanceMethodsOnActivation_#{attribute}
              attr_reader #{attribute}: ::String?
              def #{attribute}=: (::String) -> ::String
              def #{attribute}_confirmation=: (::String) -> ::String
              def authenticate_#{attribute}: (::String) -> (#{klass_name} | false)
              #{attribute == :password ? "alias authenticate authenticate_password" : ""}
            end
            include #{klass_name}::ActiveModel_SecurePassword_InstanceMethodsOnActivation_#{attribute}
          EOS
        end.compact.join("\n")
      end

      private def enum_instance_methods #: String
        # @type var methods: Array[String]
        methods = []
        defined_methods = klass.instance_methods.to_set
        klass.enum_definitions.each do |_, enum_method_name|
          ["#{enum_method_name}!", "#{enum_method_name}?"].each do |method_name|
            if defined_methods.member?(method_name.to_sym)
              methods << "def #{method_name}: () -> bool"
            end
          end
        end

        methods.join("\n")
      end

      # @rbs singleton: untyped
      private def enum_class_methods(singleton:) #: String
        # @type var methods: Array[String]
        methods = []
        defined_methods = klass.methods.to_set
        klass.enum_definitions.map(&:first).uniq.each do |name|
          column = klass.columns_hash[name.to_s] || klass.columns_hash[klass.attribute_aliases[name.to_s]]
          class_name = sql_type_to_class(column.type)
          method_name = "#{name.to_s.pluralize}"
          if defined_methods.member?(method_name.to_sym)
            methods << "def #{singleton ? 'self.' : ''}#{method_name}: () -> ::ActiveSupport::HashWithIndifferentAccess[::String, #{class_name}]"
          end
        end
        klass.enum_definitions.each do |_, enum_method_name|
          ["#{enum_method_name}", "not_#{enum_method_name}"].each do |method_name|
            if defined_methods.member?(method_name.to_sym)
              methods << "def #{singleton ? 'self.' : ''}#{method_name}: () -> #{relation_class_name}"
            end
          end
        end
        methods.join("\n")
      end

      # @rbs singleton: untyped
      private def scopes(singleton:) #: untyped
        prefix = singleton ? 'self.' : ''

        scope_definitions = klass.scope_definitions
        return "" unless scope_definitions

        enums = klass.enum_definitions.map(&:last).flat_map { [_1, "not_#{_1}"] }
        sigs = scope_definitions.map do |name, callable|
          # skip scopes generated by enum
          next if enums.include?(name.to_s)

          args = scope_method_to_type(callable)
          "def #{prefix}#{name}: #{args} -> #{relation_class_name}"
        end.compact
        sigs.join("\n")
      end

      # @rbs callable: untyped
      private def scope_method_to_type(callable) #: String
        # failed to detect arguments of scope methods.
        return '(?)' unless callable.respond_to?(:parameters)

        args = []  #: Array[String]
        block = nil

        callable.parameters.each do |type, name|
          case type
          when :req
            args << "untyped `#{name}`"
          when :opt
            args << "?untyped `#{name}`"
          when :rest
            args << "*untyped `#{name}`"
          when :keyreq
            args << "#{name}: untyped"
          when :key
            args << "?#{name}: untyped"
          when :keyrest
            args << "**untyped `#{name}`"
          when :block
            block = " { (*untyped) -> untyped }"
          end
        end

        "(#{args.join(", ")})#{block}"
      end

      private def parse_model_file #: untyped
        return @parse_model_file if defined?(@parse_model_file)

        path, _line = Object.const_source_location(klass.name) rescue nil
        return @parse_model_file = nil unless path

        begin
          @parse_model_file = parser_class.parse File.read(path)
        rescue => e
          @parse_model_file = nil
        end
      end

      private def parser_class #: untyped
        case RUBY_VERSION
        when /\A3\.2\./
          # backward campatibility
          require 'parser/ruby32'
          Parser::Ruby32
        when /\A3\.3\./
          Prism::Translation::Parser33 # steep:ignore
        when /\A3\.4\./
          Prism::Translation::Parser34 # steep:ignore
        else
          # For Prism v1.5.0+, Prism::Translation::ParserCurrent should be used instead.
          Prism::Translation::Parser34 # steep:ignore
        end
      end

      #: (Parser::AST::Node) { (Parser::AST::Node) -> untyped } -> untyped
      #: (Parser::AST::Node) -> Enumerator[Parser::AST::Node, untyped]
      private def traverse(node, &block)
        return to_enum(__method__ || raise, node) unless block

        block.call node
        node.children.each do |child|
          traverse(child, &block) if child.is_a?(Parser::AST::Node)
        end
      end

      private def relation_class_name #: String
        "#{klass_name}::ActiveRecord_Relation"
      end

      # @rbs abs: boolish
      private def klass_name(abs: true) #: String
        abs ? "::#{@klass_name}" : @klass_name
      end

      private def generated_relation_methods_name #: String
        "#{klass_name}::GeneratedRelationMethods"
      end


      private def columns #: untyped
        mod_sig = +"module #{klass_name}::GeneratedAttributeMethods\n"
        mod_sig << klass.columns.map do |col|
          # NOTE:
          #   `klass.attribute_types[col.name].try(:coder)` is for Rails 6.0 and before
          #   `klass.attribute_types[col.name]&.instance_variable_get(:@coder)` is for Rails 6.1 and after
          col_serializer = klass.attribute_types[col.name].try(:coder) ||
                           klass.attribute_types[col.name]&.instance_variable_get(:@coder)
          # e.g. ActiveRecord::Coders::JSON
          #      if your model has `serialize ..., JSON`
          # e.g. #<ActiveRecord::Coders::YAMLColumn:0x0000aaaafdc54970 @attr_name=..., @object_class=Array>
          #      if your model has `serialize ..., Array`
          # etc.
          col_serialize_to = col_serializer.try(:object_class)&.name
          if col_serializer.is_a?(Class) && col_serializer.name == 'ActiveRecord::Coders::JSON'
            class_name = 'untyped' # JSON
          elsif col_serialize_to == 'Array'
            class_name = '::Array[untyped]' # Array
          elsif col_serialize_to == 'Hash'
            class_name = '::Hash[untyped, untyped]' # Hash
          else
            class_name = if klass.enum_definitions.any? { |name, _| name == col.name.to_sym }
                           '::String'
                         else
                           sql_type_to_class(col.type)
                         end
          end
          sql_class_name = col.type == :datetime ? '::Time' : sql_type_to_class(col.type)
          # All columns are typed as nilable in the model — including `null: false`
          # ones, plus `id`/`created_at`/`updated_at`. This reflects the truth of
          # AR's two-state lifecycle: `Model.new` instances have nil-valued
          # fields until `save` runs. Non-nil narrowing for persisted/validated
          # records lives in `Model::Validated`, which is composed by
          # intersection at finder return types (`Model & Model::Validated`)
          # and on `update`/`save` truthy branches (Steep postcondition issue).
          class_name_opt = (class_name == 'untyped') ? 'untyped' : optional(class_name)
          column_type = class_name_opt
          sql_column_type = (sql_class_name == 'untyped') ? 'untyped' : optional(sql_class_name)
          sig = <<~EOS
            def #{col.name}: () -> #{column_type}
            def #{col.name}=: (#{column_type}) -> #{column_type}
            def #{col.name}?: () -> bool
            def #{col.name}_changed?: (?from: #{class_name_opt}, ?to: #{class_name_opt}) -> bool
            def #{col.name}_change: () -> [#{class_name_opt}, #{class_name_opt}]
            def #{col.name}_will_change!: () -> void
            def #{col.name}_was: () -> #{class_name_opt}
            def #{col.name}_previously_changed?: (?from: #{class_name_opt}, ?to: #{class_name_opt}) -> bool
            def #{col.name}_previous_change: () -> ::Array[#{class_name_opt}]?
            def #{col.name}_previously_was: () -> #{class_name_opt}
            def #{col.name}_before_last_save: () -> #{class_name_opt}
            def #{col.name}_change_to_be_saved: () -> ::Array[#{class_name_opt}]?
            def #{col.name}_in_database: () -> #{class_name_opt}
            def saved_change_to_#{col.name}: () -> ::Array[#{class_name_opt}]?
            def saved_change_to_#{col.name}?: () -> bool
            def will_save_change_to_#{col.name}?: () -> bool
            def restore_#{col.name}!: () -> void
            def clear_#{col.name}_change: () -> void
            def #{col.name}_before_type_cast: () -> #{sql_column_type}
            def #{col.name}_for_database: () -> #{sql_column_type}
          EOS
          sig << "\n"
          sig
        end.join("\n")
        mod_sig << "\nend\n"
        mod_sig << "include #{klass_name}::GeneratedAttributeMethods"
        mod_sig
      end

      private def alias_columns
        attribute_aliases = klass.attribute_aliases.dup
        attribute_aliases["id_value"] ||= "id" if klass.attribute_names.include?("id")

        mod_sig = +"module #{klass_name}::GeneratedAliasAttributeMethods\n"
        mod_sig << "include #{klass_name}::GeneratedAttributeMethods\n"
        mod_sig << attribute_aliases.map do |col|
          sig = <<~EOS
            alias #{col[0]} #{col[1]}
            alias #{col[0]}= #{col[1]}=
            alias #{col[0]}? #{col[1]}?
            alias #{col[0]}_changed? #{col[1]}_changed?
            alias #{col[0]}_change #{col[1]}_change
            alias #{col[0]}_will_change! #{col[1]}_will_change!
            alias #{col[0]}_was #{col[1]}_was
            alias #{col[0]}_previously_changed? #{col[1]}_previously_changed?
            alias #{col[0]}_previous_change #{col[1]}_previous_change
            alias #{col[0]}_previously_was #{col[1]}_previously_was
            alias #{col[0]}_before_last_save #{col[1]}_before_last_save
            alias #{col[0]}_change_to_be_saved #{col[1]}_change_to_be_saved
            alias #{col[0]}_in_database #{col[1]}_in_database
            alias saved_change_to_#{col[0]} saved_change_to_#{col[1]}
            alias saved_change_to_#{col[0]}? saved_change_to_#{col[1]}?
            alias will_save_change_to_#{col[0]}? will_save_change_to_#{col[1]}?
            alias restore_#{col[0]}! restore_#{col[1]}!
            alias clear_#{col[0]}_change clear_#{col[1]}_change
            alias #{col[0]}_before_type_cast #{col[1]}_before_type_cast
            alias #{col[0]}_for_database #{col[1]}_for_database
          EOS
          sig << "\n"
          sig
        end.join("\n")
        mod_sig << "\nend\n"
        mod_sig << "include #{klass_name}::GeneratedAliasAttributeMethods"
        mod_sig
      end

      # @rbs class_name: String
      private def optional(class_name) #: String
        class_name.include?("|") ? "(#{class_name})?" : "#{class_name}?"
      end

      # @rbs t: untyped
      private def sql_type_to_class(t) #: untyped
        case t
        when :integer
          '::Integer'
        when :float
          '::Float'
        when :decimal
          '::BigDecimal'
        when :string, :text, :citext, :uuid, :binary
          '::String'
        when :datetime
          '::ActiveSupport::TimeWithZone'
        when :boolean
          "bool"
        when :jsonb, :json
          "untyped"
        when :date
          '::Date'
        when :time
          '::Time'
        when :inet
          "::IPAddr"
        else
          # Unknown column type, give up
          'untyped'
        end
      end

      private
      attr_reader :klass #: singleton(ActiveRecord::Base) & Enum & Scope
    end
  end
end
