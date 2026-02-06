module RMake
  class Graph
    Node = Struct.new(:name, :deps, :order_only, :recipe, :phony, :precious, :double_colon, :target_vars)

    def initialize
      @nodes = {}
      @suffix_rules = []
      @suffix_by_dst = {}
    end

    def add_rule(rule, phony: false, precious: false)
      rule.targets.each do |t|
        node = (@nodes[t] ||= Node.new(t, [], [], [], false, false, rule.double_colon, {}))
        node.deps.concat(rule.prereqs)
        node.order_only.concat(rule.order_only)
        node.phony ||= phony
        node.precious ||= precious
        if rule.recipe.any?
          if rule.double_colon
            node.recipe.concat(rule.recipe)
          else
            node.recipe = rule.recipe
          end
        end
      end
    end

    def add_suffix_rule(src, dst, prereqs, recipe)
      @suffix_rules << [src, dst, prereqs, recipe]
      (@suffix_by_dst[dst] ||= []) << [src, dst, prereqs, recipe]
    end

    def node(name)
      @nodes[name]
    end

    def ensure_node(name)
      @nodes[name] ||= Node.new(name, [], [], [], false, false, false, {})
    end

    def nodes
      @nodes.values
    end

    def implicit_rules_for(target)
      rules = []
      @suffix_by_dst.each do |dst, list|
        next unless target.end_with?(dst)
        list.each { |r| rules << r }
      end
      if rules.empty?
        @suffix_rules.each do |r|
          rules << r if target.end_with?(r[1])
        end
      end
      rules
    end
  end
end
