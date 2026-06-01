require "prism"

module RbsRails
  # Walks a model source file and extracts ActiveRecord *after-validation*
  # lifecycle callbacks bound to literal Symbol handlers, for the
  # `applies_self` entries of `.steep_callbacks.yml` (consumed by
  # `Steep::Callbacks`, felixefelip/steep#27).
  #
  # Only callbacks that run AFTER the record's validations pass are emitted,
  # so refining `self` to `Model & Model::Validated` at the handler's entry is
  # sound (the record is known to satisfy its presence validations). In the
  # save lifecycle (before_validation → validate → after_validation →
  # before_save → before_create/update → INSERT/UPDATE → after_create/update →
  # after_save → after_commit), every callback except `before_validation` runs
  # post-validation:
  #
  #   after_validation, before_save, before_create, before_update,
  #   after_create, after_update, after_save, after_commit
  #
  # Skipped (valid Rails the generator can't soundly translate, no warning):
  #   - conditional callbacks (`if:` / `unless:`)
  #   - block / proc / callable-object handlers (only literal Symbols)
  #
  # Out of scope: `before_validation` (runs pre-validation), and
  # `after_destroy` / `*_rollback` (don't establish the presence-validated
  # invariant).
  class ModelCallbacksGenerator
    AFTER_VALIDATION_CALLBACKS = %i[
      after_validation
      before_save
      before_create
      before_update
      after_save
      after_create
      after_update
      after_commit
    ].freeze

    # @rbs source: String -- Ruby source to parse
    # @rbs path: String? -- file path for error messages (optional)
    def initialize(source:, path: nil)
      @source = source
      @path = path
    end

    # Returns `Hash[full_class_name, Array[Symbol]]` mapping each class that
    # declares post-validation callbacks to the method symbols whose `self`
    # should be narrowed to `Model::Validated` — the callback handlers plus the
    # transitive closure of same-class instance methods they reach via
    # implicit-self calls.
    def callbacks_by_class #: Hash[String, Array[Symbol]]
      tree = Prism.parse(@source).value
      result = {} #: Hash[String, Array[Symbol]]
      walk(tree, namespace: [], result: result)
      result
    end

    private

    def walk(node, namespace:, result:)
      case node
      when Prism::ProgramNode
        walk(node.statements, namespace: namespace, result: result)
      when Prism::StatementsNode
        node.body.each { |child| walk(child, namespace: namespace, result: result) }
      when Prism::ModuleNode
        mod_name = constant_path_to_s(node.constant_path)
        walk(node.body, namespace: namespace + [mod_name], result: result) if node.body && mod_name
      when Prism::ClassNode
        class_name = constant_path_to_s(node.constant_path)
        return unless class_name
        full_name = (namespace + [class_name]).join("::")
        emit_for_class(node, full_name, result)
        walk(node.body, namespace: namespace + [class_name], result: result) if node.body
      end
    end

    def emit_for_class(class_node, full_name, result)
      body = class_node.body
      return unless body

      children =
        case body
        when Prism::StatementsNode then body.body
        else [body]
        end

      roots = [] #: Array[Symbol]
      defs = {} #: Hash[Symbol, Prism::DefNode]
      children.each do |child|
        case child
        when Prism::CallNode
          if child.receiver.nil? && AFTER_VALIDATION_CALLBACKS.include?(child.name)
            roots.concat(handler_symbols(child))
          end
        when Prism::DefNode
          # Instance methods only (skip `def self.x`).
          defs[child.name] = child if child.receiver.nil?
        end
      end

      return if roots.empty?

      closure = transitive_self_call_closure(roots, defs)
      result[full_name] = closure unless closure.empty?
    end

    # The callback narrows `self` to `Model::Validated` at the handler's entry,
    # but a handler typically delegates to helper methods (`calcular_status` ->
    # `tomou_todas_as_doses?` -> `qtde_doses_tomadas` -> ...). Each of those is
    # type-checked with its own `self`, so without help the validated narrowing
    # is lost one hop in. We therefore return the transitive closure of
    # same-class instance methods reachable from the callback via implicit-self
    # calls, so every method reachable from a post-validation callback gets the
    # narrowing too. Methods not defined in this class (association readers,
    # inherited helpers) are left as-is.
    def transitive_self_call_closure(roots, defs)
      visited = [] #: Array[Symbol]
      queue = roots.dup #: Array[Symbol]

      until queue.empty?
        name = queue.shift
        next if visited.include?(name)
        visited << name

        def_node = defs[name]
        next unless def_node

        self_calls_in(def_node.body).each do |callee|
          queue << callee if defs.key?(callee) && !visited.include?(callee)
        end
      end

      visited.uniq
    end

    # Names of self method calls anywhere within a node's subtree — both
    # receiver-less sends (`foo`, `foo&.x`) and explicit `self.foo`. Calls with
    # any other receiver (`vacina.count`, `Foo.bar`) are not self-calls and are
    # left out.
    def self_calls_in(node, acc = [])
      return acc unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        acc << node.name
      end
      node.compact_child_nodes.each { |child| self_calls_in(child, acc) }
      acc
    end

    # Returns the literal Symbol handlers of a callback call, or `[]` if the
    # whole call must be skipped (conditional, block, proc/lambda, callable
    # object, or no symbol handler).
    def handler_symbols(call)
      return [] if call.block # after_save { ... }

      args = call.arguments&.arguments || []
      return [] if args.empty?

      syms = [] #: Array[Symbol]
      args.each do |arg|
        case arg
        when Prism::SymbolNode
          sym = arg.value&.to_sym
          syms << sym if sym
        when Prism::KeywordHashNode, Prism::HashNode
          # Options hash: `on:`/`prepend:` are fine, but `if:`/`unless:` make
          # the callback conditional — skip the whole declaration.
          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            next unless assoc.key.is_a?(Prism::SymbolNode)
            return [] if %w[if unless].include?(assoc.key.value)
          end
        else
          # proc, lambda, callable object — can't translate this handler.
          return []
        end
      end

      syms
    end

    def constant_path_to_s(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = constant_path_to_s(node.parent)
        return nil unless parent
        "#{parent}::#{node.name}"
      end
    end
  end
end
