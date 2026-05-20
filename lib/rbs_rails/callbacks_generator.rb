require "prism"

module RbsRails
  # Walks a Ruby source file (controller, mailer, channel, etc.) and
  # extracts `before_action` declarations into entries for the
  # `.steep_callbacks.yml` sidecar consumed by Steep
  # (felixefelip/steep#27).
  #
  # The intent is to let Steep apply a handler's `unconditional`
  # postcondition at the entry of every action the callback covers, so
  # `before_action :set_post` makes `@post` non-nil inside `show`, `edit`,
  # etc. without the action calling `set_post` explicitly.
  #
  # Scope (V1):
  #
  # - Only `before_action` (not `after_action`/`around_action`).
  # - Only handlers passed as a literal `Symbol` argument.
  # - Only `:only` / `:except` keywords for action selection.
  # - Inheritance is intentionally NOT walked: only declarations on the
  #   class itself are emitted. A controller that relies on a
  #   `before_action` inherited from `ApplicationController` won't get
  #   that callback in its sidecar entry. Documented limitation;
  #   follow-up.
  # - Skipped (no entry emitted, with no warning — these are valid Rails
  #   patterns the generator just can't translate):
  #   - `before_action :foo, if: :predicate?` (conditional)
  #   - `before_action :foo, unless: :predicate?` (conditional)
  #   - `before_action { ... }` (anonymous block)
  #   - `before_action ->(c) { ... }` (proc/lambda)
  #   - `before_action SomeClass.new` (callback object)
  class CallbacksGenerator
    # Output shape:
    #
    #   {
    #     "class" => "PostsController",
    #     "apply_postcondition_of" => "set_post",
    #     "runs_before" => [:show, :edit, :update, :destroy, :publish]
    #   }
    #
    # @rbs source: String -- Ruby source to parse
    # @rbs path: String? -- file path for error messages (optional)
    def initialize(source:, path: nil)
      @source = source
      @path = path
    end

    # Returns the list of sidecar entries discovered in the source.
    # Each entry is a `Hash[String, untyped]` ready for YAML dump.
    def entries
      tree = Prism.parse(@source).value
      result = [] #: Array[Hash[String, untyped]]
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
        # Descend in case of nested classes/modules
        walk(node.body, namespace: namespace + [class_name], result: result) if node.body
      end
    end

    # Collects `before_action` and `skip_before_action` at direct class
    # body scope and emits one entry per usable callback.
    def emit_for_class(class_node, full_class_name, result)
      body = class_node.body
      return unless body

      direct_children =
        case body
        when Prism::StatementsNode then body.body
        else [body]
        end

      actions = collect_public_actions(direct_children)
      return if actions.empty?

      callbacks = [] #: Array[Hash[Symbol, untyped]]
      skips = [] #: Array[Hash[Symbol, untyped]]

      direct_children.each do |child|
        next unless child.is_a?(Prism::CallNode)
        next unless implicit_self?(child)
        case child.name
        when :before_action
          parsed = parse_callback_call(child)
          callbacks << parsed if parsed
        when :skip_before_action
          parsed = parse_callback_call(child)
          skips << parsed if parsed
        end
      end

      return if callbacks.empty?

      callbacks.each do |cb|
        runs_before = resolve_runs_before(cb, actions: actions)
        # Subtract any matching skip_before_action against the same handler.
        skips.each do |skip|
          next unless skip[:handler] == cb[:handler]
          skipped = resolve_runs_before(skip, actions: actions)
          runs_before = runs_before - skipped
        end

        next if runs_before.empty?

        result << {
          "class" => full_class_name,
          "apply_postcondition_of" => cb[:handler].to_s,
          "runs_before" => runs_before.map(&:to_s)
        }
      end
    end

    # Parses a `:before_action`/`:skip_before_action` call. Returns a hash
    # with `:handler` (Symbol), `:only` (Array[Symbol]?), `:except`
    # (Array[Symbol]?). Returns nil for any pattern the generator can't
    # handle (block, proc, `if:`/`unless:`, missing handler, etc.).
    def parse_callback_call(call)
      args = call.arguments&.arguments || []
      return nil if call.block # `before_action { ... }`
      return nil if args.empty?

      first = args[0]
      handler =
        case first
        when Prism::SymbolNode then first.value&.to_sym
        else return nil # proc, lambda, callback object, etc.
        end
      return nil unless handler

      only = nil
      except = nil
      conditional = false

      args[1..].to_a.each do |arg|
        case arg
        when Prism::KeywordHashNode, Prism::HashNode
          arg.elements.each do |assoc|
            next unless assoc.is_a?(Prism::AssocNode)
            next unless assoc.key.is_a?(Prism::SymbolNode)
            key = assoc.key.value
            case key
            when "only"
              only = extract_symbol_list(assoc.value)
              return nil unless only
            when "except"
              except = extract_symbol_list(assoc.value)
              return nil unless except
            when "if", "unless"
              # Conditional — V1 treats as "may not run", don't emit.
              conditional = true
            end
          end
        end
      end

      return nil if conditional

      { handler: handler, only: only, except: except }
    end

    # `:show` → [:show]. `[:show, :edit]` → [:show, :edit]. `%i[a b]` →
    # [:a, :b]. Anything else (variable, method call, splat) → nil.
    def extract_symbol_list(node)
      case node
      when Prism::SymbolNode
        sym = node.value&.to_sym
        sym ? [sym] : nil
      when Prism::ArrayNode
        syms = node.elements.map do |elem|
          case elem
          when Prism::SymbolNode then elem.value&.to_sym
          else return nil
          end
        end
        syms.compact.empty? ? nil : syms.compact
      end
    end

    # Returns the public actions covered by a parsed callback.
    def resolve_runs_before(callback, actions:)
      if callback[:only]
        callback[:only] & actions
      elsif callback[:except]
        actions - callback[:except]
      else
        actions
      end
    end

    # Public actions are top-level `def`s in the class body that aren't
    # preceded by `private`/`protected` (treated as block-style sections
    # introduced by a bareword call with no args). This is the same
    # convention Rails uses for action filtering.
    def collect_public_actions(direct_children)
      result = [] #: Array[Symbol]
      visibility = :public

      direct_children.each do |child|
        case child
        when Prism::CallNode
          if child.arguments.nil? && child.receiver.nil?
            case child.name
            when :private then visibility = :private
            when :protected then visibility = :protected
            when :public then visibility = :public
            end
          end
        when Prism::DefNode
          result << child.name if visibility == :public && child.receiver.nil?
        end
      end

      result
    end

    # `self.foo`, `Foo.foo`, etc. are NOT class-body declarations of the
    # filter API; we only handle implicit-self calls.
    def implicit_self?(call)
      call.receiver.nil?
    end

    # `Foo::Bar` → "Foo::Bar". `Bar` → "Bar". `::Bar` → "::Bar".
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
