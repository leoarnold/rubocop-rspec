# frozen_string_literal: true

module RuboCop
  module Cop
    module RSpec
      module FactoryBot
        # Checks for create_list usage.
        #
        # This cop can be configured using the `EnforcedStyle` option
        #
        # @example `EnforcedStyle: list` (default)
        #   # bad
        #   build_pair(:user)
        #   3.times { build(:user) }
        #   3.times { |n| create(:user, created_at: n.months.ago) }
        #   create_pair(:user) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #
        #   # good
        #   build_list(:user, 2)
        #   build_list(:user, 3)
        #   create_list(:user, 3) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #   create_list(:user, 2) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #
        # @example `EnforcedStyle: list_and_pair`
        #   # bad
        #   2.times { build(:user) }
        #   3.times { build(:user) }
        #   2.times { |n| create(:user, created_at: n.months.ago) }
        #   3.times { |n| create(:user, created_at: n.months.ago) }
        #
        #   # good
        #   build_pair(:user)
        #   build_list(:user, 3)
        #   create_pair(:user) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #   create_list(:user, 3) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #
        # @example `EnforcedStyle: n_times`
        #   # bad
        #   build_pair(:user)
        #   build_list(:user, 3)
        #   create_pair(:user) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #   create_list(:user, 3) do |user, n|
        #     user.created_at = n.months.ago
        #   end
        #
        #   # good
        #   2.times { build(:user) }
        #   3.times { build(:user) }
        #   2.times { |n| create_pair(:user, user.created_at = n.months.ago) }
        #   3.times { |n| create_pair(:user, user.created_at = n.months.ago) }
        #
        class MultipleInstances < Base
          extend AutoCorrector
          include ConfigurableEnforcedStyle
          include RuboCop::RSpec::FactoryBot::Language

          MSG_CREATE_LIST = 'Prefer create_list.'
          MSG_N_TIMES = 'Prefer %<number>s.times.'
          RESTRICT_ON_SEND = SYNTAX_METHODS

          # @!method n_times_block_without_arg?(node)
          def_node_matcher :n_times_block_without_arg?, <<-PATTERN
            (block
              (send (int _) :times)
              (args)
              ...
            )
          PATTERN

          # @!method factory_call(node)
          def_node_matcher :factory_call, <<-PATTERN
            (send ${nil? #factory_bot?} :create (sym $_) $...)
          PATTERN

          # @!method factory_list_call(node)
          def_node_matcher :factory_list_call, <<-PATTERN
            (send {nil? #factory_bot?} :create_list (sym _) (int $_) ...)
          PATTERN

          def on_block(node)
            return unless style == :list
            return unless n_times_block_without_arg?(node)
            return unless contains_only_factory?(node.body)

            add_offense(node.send_node, message: MSG_CREATE_LIST) do |corrector|
              CreateListCorrector.new(node.send_node).call(corrector)
            end
          end

          def on_send(node)
            return unless style == :n_times

            factory_list_call(node) do |count|
              message = format(MSG_N_TIMES, number: count)
              add_offense(node.loc.selector, message: message) do |corrector|
                TimesCorrector.new(node).call(corrector)
              end
            end
          end

          private

          def contains_only_factory?(node)
            if node.block_type?
              factory_call(node.send_node)
            else
              factory_call(node)
            end
          end

          # :nodoc
          module Corrector
            private

            def build_options_string(options)
              options.map(&:source).join(', ')
            end

            def format_method_call(node, method, arguments)
              if node.block_type? || node.parenthesized?
                "#{method}(#{arguments})"
              else
                "#{method} #{arguments}"
              end
            end

            def format_receiver(receiver)
              return '' unless receiver

              "#{receiver.source}."
            end
          end

          # :nodoc
          class TimesCorrector
            include Corrector

            def initialize(node)
              @node = node
            end

            def call(corrector)
              replacement = generate_n_times_block(node)
              corrector.replace(node, replacement)
            end

            private

            attr_reader :node

            def generate_n_times_block(node)
              factory, count, *options = node.arguments

              arguments = factory.source
              options = build_options_string(options)
              arguments += ", #{options}" unless options.empty?

              replacement = format_receiver(node.receiver)
              replacement += format_method_call(node, 'create', arguments)
              "#{count.source}.times { #{replacement} }"
            end
          end

          # :nodoc:
          class CreateListCorrector
            include Corrector

            def initialize(node)
              @node = node.parent
            end

            def call(corrector)
              replacement = if node.body.block_type?
                              call_with_block_replacement(node)
                            else
                              call_replacement(node)
                            end

              corrector.replace(node, replacement)
            end

            private

            attr_reader :node

            def call_with_block_replacement(node)
              block = node.body
              arguments = build_arguments(block, node.receiver.source)
              replacement = format_receiver(block.send_node.receiver)
              replacement += format_method_call(block, 'create_list', arguments)
              replacement += format_block(block)
              replacement
            end

            def build_arguments(node, count)
              factory, *options = *node.send_node.arguments

              arguments = ":#{factory.value}, #{count}"
              options = build_options_string(options)
              arguments += ", #{options}" unless options.empty?
              arguments
            end

            def call_replacement(node)
              block = node.body
              factory, *options = *block.arguments

              arguments = "#{factory.source}, #{node.receiver.source}"
              options = build_options_string(options)
              arguments += ", #{options}" unless options.empty?

              replacement = format_receiver(block.receiver)
              replacement += format_method_call(block, 'create_list', arguments)
              replacement
            end

            def format_block(node)
              if node.body.begin_type?
                format_multiline_block(node)
              else
                format_singeline_block(node)
              end
            end

            def format_multiline_block(node)
              indent = ' ' * node.body.loc.column
              indent_end = ' ' * node.parent.loc.column
              " do #{node.arguments.source}\n" \
              "#{indent}#{node.body.source}\n" \
              "#{indent_end}end"
            end

            def format_singeline_block(node)
              " { #{node.arguments.source} #{node.body.source} }"
            end
          end
        end
      end
    end
  end
end
