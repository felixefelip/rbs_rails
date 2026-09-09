require "prism"

module RbsRails
  # Walks a model (or model concern) source file and extracts ActiveRecord
  # *after-validation* lifecycle callbacks bound to literal Symbol handlers, for
  # the `applies_self` entries of `.steep_callbacks.yml` (consumed by
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
  # The `after_*_commit` sugar is included too: `after_create_commit`,
  # `after_update_commit` and `after_save_commit` are `after_commit on:` in
  # disguise, so they run later still — the record is not merely validated but
  # committed. (`after_destroy_commit` is left out with `after_destroy`.)
  #
  # Conditional callbacks (`if:` / `unless:`) ARE included: the condition only
  # gates WHETHER the callback runs, never moving it before validation. A
  # handler that runs is still post-validation, so refining `self` to
  # `Model & Model::Validated` at its entry stays sound (felixefelip/rbs_rails:
  # `after_update :handle_board_change, if: :saved_change_to_board_id?` is just
  # as validated as an unconditional `after_update`).
  #
  # ## Callbacks declared in a concern
  #
  # The dominant Rails shape puts the macro in a concern's `included do` block
  # and the handler in the concern's own body:
  #
  #     module User::Accessor
  #       extend ActiveSupport::Concern
  #       included do
  #         after_create_commit :grant_access_to_boards, unless: :system?
  #       end
  #
  #       private
  #         def grant_access_to_boards
  #           account.boards          # `account` is a required belongs_to
  #         end
  #     end
  #
  # The callback runs on the HOST (`User`), so the narrowing is the host's
  # `User & User::Validated` — but the handler's body is type-checked in the
  # CONCERN's scope, so the sidecar entry has to be keyed `User::Accessor`.
  # That is the key this generator returns for a def in the module body. A def
  # written inside `included do` lands on the host instead, and is keyed by
  # `host:` when the caller passes it (nil host: such a def is skipped rather
  # than mis-keyed).
  #
  # ## Callbacks reaching across files
  #
  # The closure below follows implicit-self calls, and a handler routinely calls
  # into a concern the model includes:
  #
  #     class Card                            # app/models/card.rb
  #       after_update :handle_board_change
  #       private def handle_board_change = clean_inaccessible_data_later
  #     end
  #
  #     module Card::Accessible               # app/models/card/accessible.rb
  #       private def clean_inaccessible_data_later
  #         Card::CleanInaccessibleDataJob.perform_later(self)
  #       end
  #     end
  #
  # Read one file at a time, the root and the def it reaches are in different
  # scans and the closure stops at the file boundary — leaving the concern's
  # method with its declared `self` (`Card & Card::Accessible`), which is how
  # `perform_later(self)` handed the job an unvalidated `Card` and the
  # precondition on `Card::Accessible#clean_inaccessible_data` went unenforced.
  # `callbacks_across` merges the model's files into one closure so it does not.
  #
  # Skipped (valid Rails the generator can't soundly translate, no warning):
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
      after_create_commit
      after_update_commit
      after_save_commit
    ].freeze

    # A scope's raw material for the closure: the callback handler names the
    # scope declares, and the instance methods its body defines.
    #
    # `roots` carries each handler's DECLARING scope alongside its name, because
    # a handler with no def anywhere (an association writer such as the
    # `create_settings` of `has_one :settings`) has no owner to be filed under
    # and falls back to where it was declared.
    Scan = Struct.new(:roots, :defs, keyword_init: true)

    # @rbs source: String -- Ruby source to parse
    # @rbs path: String? -- file path for error messages (optional)
    # @rbs host: String? -- the class a concern in this file is included into,
    #   which owns the methods its `included do` defines (optional)
    def initialize(source:, path: nil, host: nil)
      @source = source
      @path = path
      @host = host
    end

    # Returns `Hash[scope_name, Array[Symbol]]` mapping each scope that owns
    # post-validation callback handlers to the method symbols whose `self`
    # should be narrowed to the host's `Validated` marker — the callback
    # handlers plus the transitive closure of same-scope instance methods they
    # reach via implicit-self calls.
    #
    # A scope is the class or concern module Steep type-checks the handler in,
    # which is the key `.steep_callbacks.yml` matches on — not necessarily the
    # class the callback runs on (see "Callbacks declared in a concern").
    #
    # One file, one closure per scope in it. Use `callbacks_across` for a model
    # whose declarations are spread over several files — which is the norm, and
    # what "Callbacks reaching across files" above is about.
    def callbacks_by_class #: Hash[String, Array[Symbol]]
      scan.each_with_object({}) do |(_scope, scanned), result|
        next if scanned.roots.empty?

        self.class.close(roots: scanned.roots, defs: scanned.defs).each do |owner, methods|
          (result[owner] ||= []).concat(methods)
        end
      end.each_value(&:uniq!)
    end

    # `Hash[scope_name, Scan]` for every class/module body in this source, with
    # no closure computed and no scope dropped for having no roots: a scope with
    # only defs still contributes them to a closure rooted elsewhere.
    def scan #: Hash[String, Scan]
      tree = Prism.parse(@source).value
      result = {} #: Hash[String, Scan]
      walk(tree, namespace: [], result: result)
      result
    end

    # One closure over ONE MODEL's whole corpus — its own file and each concern
    # in its ancestry — rather than one per file.
    #
    # `sources` is `[[scope owner, source, path], ...]` in method-resolution
    # order (the model first, then its ancestors), where "scope owner" is the
    # scope the file was opened for: only that scope and the model's own are
    # read from it, so an unrelated class sharing the file answers to its own
    # generator.
    #
    # Merging is what makes a callback declared in the model reach a handler
    # defined in a concern:
    #
    #     class Card                          # app/models/card.rb
    #       after_update :handle_board_change
    #       def handle_board_change = clean_inaccessible_data_later
    #     end
    #
    #     module Card::Accessible             # app/models/card/accessible.rb
    #       def clean_inaccessible_data_later = Card::CleanJob.perform_later(self)
    #     end
    #
    # Per file the root `handle_board_change` and the def it reaches live in
    # different scans, so the closure stopped at the file boundary and
    # `clean_inaccessible_data_later` kept the concern's declared `self`
    # (`Card & Card::Accessible`) instead of the callback's
    # `Card & Card::Validated`. Each method is still filed under the scope that
    # OWNS it — the concern here — because that is the scope Steep checks its
    # body in.
    #
    # First definition wins when two scopes define the same name, which is
    # Ruby's own resolution given `sources` in MRO order.
    #
    # @rbs sources: Array[[String, String, String?]]
    # @rbs host: String?
    def self.callbacks_across(sources, host:) #: Hash[String, Array[Symbol]]
      roots = [] #: Array[[Symbol, String]]
      defs = {} #: Hash[Symbol, [Prism::DefNode, String?]]

      sources.each do |scope_owner, source, path|
        new(source: source, path: path, host: host).scan.each do |scope, scanned|
          next unless scope == host || scope == scope_owner

          roots.concat(scanned.roots)
          scanned.defs.each { |name, entry| defs[name] ||= entry }
        end
      end

      close(roots: roots, defs: defs)
    end

    # `Hash[owner scope, Array[Symbol]]` — the transitive closure of `roots`
    # over `defs`, each method filed under the scope that owns it.
    #
    # @rbs roots: Array[[Symbol, String]]
    # @rbs defs: Hash[Symbol, [Prism::DefNode, String?]]
    def self.close(roots:, defs:) #: Hash[String, Array[Symbol]]
      declared_in = {} #: Hash[Symbol, String]
      roots.each { |name, scope| declared_in[name] ||= scope }

      result = {} #: Hash[String, Array[Symbol]]
      transitive_self_call_closure(declared_in.keys, defs).each do |name|
        # A handler with no def anywhere (an association writer such as the
        # `create_settings` of `has_one :settings`) is filed under the scope
        # that declared it: nothing is checked under that name, so the entry is
        # inert. A def whose owner is the includer is dropped when no `host:`
        # was given — better absent than keyed to the concern, where it is not
        # checked.
        entry = defs[name]
        owner = entry ? entry.last : declared_in[name]
        next unless owner

        (result[owner] ||= []) << name
      end
      result.each_value(&:uniq!)
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
        return unless mod_name
        full_name = (namespace + [mod_name]).join("::")
        scan_scope(node, full_name, result)
        walk(node.body, namespace: namespace + [mod_name], result: result) if node.body
      when Prism::ClassNode
        class_name = constant_path_to_s(node.constant_path)
        return unless class_name
        full_name = (namespace + [class_name]).join("::")
        scan_scope(node, full_name, result)
        walk(node.body, namespace: namespace + [class_name], result: result) if node.body
      end
    end

    # Collects one class/module body's callback roots and instance methods.
    #
    # Two owners are in play, and only in a concern do they differ: a def in the
    # body belongs to `full_name` itself, while a def inside `included do`
    # belongs to the includer (`@host`) — the same split `included do` has
    # everywhere, since its block is `class_eval`d on the host.
    def scan_scope(scope_node, full_name, result)
      body = scope_node.body
      return unless body

      roots = [] #: Array[[Symbol, String]]
      defs = {} #: Hash[Symbol, [Prism::DefNode, String?]]

      statements(body).each do |child|
        case child
        when Prism::CallNode
          if child.receiver.nil? && AFTER_VALIDATION_CALLBACKS.include?(child.name)
            handler_symbols(child).each { |name| roots << [name, full_name] }
          elsif included_block(child)
            statements(included_block(child)).each do |inner|
              case inner
              when Prism::CallNode
                if inner.receiver.nil? && AFTER_VALIDATION_CALLBACKS.include?(inner.name)
                  handler_symbols(inner).each { |name| roots << [name, full_name] }
                end
              when Prism::DefNode
                defs[inner.name] ||= [inner, @host] if inner.receiver.nil?
              end
            end
          end
        when Prism::DefNode
          # Instance methods only (skip `def self.x`).
          defs[child.name] = [child, full_name] if child.receiver.nil?
        end
      end

      result[full_name] = Scan.new(roots: roots, defs: defs)
    end

    def statements(node)
      case node
      when Prism::StatementsNode then node.body
      when Prism::Node then [node]
      else []
      end
    end

    # The body of a receiver-less `included do ... end`, or nil for any other
    # call. `ActiveSupport::Concern`'s hook and the hand-rolled equivalent look
    # the same here, which is all this needs.
    def included_block(call)
      return nil unless call.receiver.nil? && call.name == :included

      block = call.block
      block.is_a?(Prism::BlockNode) ? block.body : nil
    end

    # The callback narrows `self` to `Model::Validated` at the handler's entry,
    # but a handler typically delegates to helper methods (`calcular_status` ->
    # `tomou_todas_as_doses?` -> `qtde_doses_tomadas` -> ...). Each of those is
    # type-checked with its own `self`, so without help the validated narrowing
    # is lost one hop in. We therefore return the transitive closure of
    # same-scope instance methods reachable from the callback via implicit-self
    # calls, so every method reachable from a post-validation callback gets the
    # narrowing too. Methods not defined in this scope (association readers,
    # inherited helpers) are left as-is.
    #
    # `defs` maps a method name to `[def node, owning scope]`; the closure needs
    # only the node — the caller files each name under its owner.
    def self.transitive_self_call_closure(roots, defs)
      visited = [] #: Array[Symbol]
      queue = roots.dup #: Array[Symbol]

      until queue.empty?
        name = queue.shift
        next if visited.include?(name)
        visited << name

        def_node, _owner = defs[name]
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
    def self.self_calls_in(node, acc = [])
      return acc unless node.is_a?(Prism::Node)

      if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        acc << node.name
      end
      node.compact_child_nodes.each { |child| self_calls_in(child, acc) }
      acc
    end
    private_class_method :transitive_self_call_closure, :self_calls_in

    # Returns the literal Symbol handlers of a callback call, or `[]` if the
    # whole call must be skipped (block, proc/lambda, callable object, or no
    # symbol handler). Conditional `if:`/`unless:` callbacks are NOT skipped —
    # the condition doesn't affect the post-validation invariant.
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
          # Options hash (`on:`, `prepend:`, `if:`, `unless:`): no handler
          # symbols to collect, and none of these options affect the
          # post-validation invariant — `if:`/`unless:` only gate whether the
          # callback runs, not when, so the handler is still post-validation
          # whenever it runs. Ignore the hash.
          next
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
