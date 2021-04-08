# frozen_string_literal: true

require 'spree/preferences/persistable'
require 'spree/preferences/statically_configurable'

module Spree
  # A base class which is used for implementing payment methods.
  #
  # Uses STI (single table inheritance) to store all implemented payment methods
  # in one table (+spree_payment_methods+).
  #
  # This class is not meant to be instantiated. Please create instances of concrete payment methods.
  #
  class PaymentMethod < Spree::Base
    include Spree::Preferences::Persistable

    preference :server, :string, default: 'test'
    preference :test_mode, :boolean, default: true

    include Spree::SoftDeletable

    acts_as_list

    validates :name, :type, presence: true

    has_many :payments, class_name: "Spree::Payment", inverse_of: :payment_method
    has_many :credit_cards, class_name: "Spree::CreditCard"
    has_many :store_payment_methods, inverse_of: :payment_method
    has_many :stores, through: :store_payment_methods

    scope :ordered_by_position, -> { order(:position) }
    scope :active, -> { where(active: true) }
    scope :available_to_users, -> { where(available_to_users: true) }
    scope :available_to_admin, -> { where(available_to_admin: true) }
    scope :available_to_store, ->(store) do
      raise ArgumentError, "You must provide a store" if store.nil?
      store.payment_methods.empty? ? all : where(id: store.payment_method_ids)
    end

    delegate :authorize, :purchase, :capture, :void, :credit, to: :gateway

    include Spree::Preferences::StaticallyConfigurable

    # Custom ModelName#human implementation to ensure we don't refer to
    # subclasses as just "PaymentMethod"
    class ModelName < ActiveModel::Name
      # Similar to ActiveModel::Name#human, but skips lookup_ancestors
      def human(options = {})
        defaults = [
          i18n_key,
          options[:default],
          @human
        ].compact
        options = { scope: [:activerecord, :models], count: 1, default: defaults }.merge!(options.except(:default))
        I18n.translate(defaults.shift, **options)
      end
    end

    class << self
      def model_name
        ModelName.new(self, Spree)
      end
    end

    # Represents the gateway of this payment method
    #
    # The gateway is responsible for communicating with the providers API.
    #
    # It implements methods for:
    #
    #     - authorize
    #     - purchase
    #     - capture
    #     - void
    #     - credit
    #
    def gateway
      gateway_options = options
      gateway_options.delete :login if gateway_options.key?(:login) && gateway_options[:login].nil?

      # All environments except production considered to be test
      test_server = gateway_options[:server] != 'production'
      test_mode = gateway_options[:test_mode]

      gateway_options[:test] = (test_server || test_mode)

      @gateway ||= gateway_class.new(gateway_options)
    end

    # Represents all preferences as a Hash
    #
    # Each preference is a key holding the value(s) and gets passed to the gateway via +gateway_options+
    #
    # @return Hash
    def options
      preferences.to_hash
    end

    # The class that will store payment sources (re)usable with this payment method
    #
    # Used by Spree::Payment as source (e.g. Spree::CreditCard in the case of a credit card payment method).
    #
    # Returning nil means the payment method doesn't support storing sources (e.g. Spree::PaymentMethod::Check)
    def payment_source_class
      raise ::NotImplementedError, "You must implement payment_source_class method for #{self.class}."
    end

    # Used as partial name for your payment method
    #
    # Currently your payment method needs to provide these partials:
    #
    #     1. app/views/spree/checkout/payment/_{partial_name}.html.erb
    #     The form your customer enters the payment information in during checkout
    #
    #     2. app/views/spree/checkout/existing_payment/_{partial_name}.html.erb
    #     The payment information of your customers reusable sources during checkout
    #
    #     3. app/views/spree/admin/payments/source_forms/_{partial_name}.html.erb
    #     The form an admin enters payment information in when creating orders in the backend
    #
    #     4. app/views/spree/admin/payments/source_views/_{partial_name}.html.erb
    #     The view that represents your payment method on orders in the backend
    #
    #     5. app/views/spree/api/payments/source_views/_{partial_name}.json.jbuilder
    #     The view that represents your payment method on orders through the api
    #
    def partial_name
      type.demodulize.underscore
    end

    def payment_profiles_supported?
      false
    end

    def source_required?
      true
    end

    # Custom gateways can redefine this method to return reusable sources for an order.
    # See {Spree::PaymentMethod::CreditCard#reusable_sources} as an example
    def reusable_sources(_order)
      []
    end

    def auto_capture?
      auto_capture.nil? ? Spree::Config[:auto_capture] : auto_capture
    end

    # Check if given source is supported by this payment method
    #
    # Please implement validation logic in your payment method implementation
    #
    # @see Spree::PaymentMethod::CreditCard#supports?
    def supports?(_source)
      true
    end

    # Used by Spree::Payment#cancel!
    #
    # Implement `try_void` on your payment method implementation to handle void attempts.
    # In that method return a ActiveMerchant::Billing::Response object if the void succeeds.
    # Return +false+ or +nil+ if the void is not possible anymore - because it was already processed by the bank.
    # Solidus will refund the amount of the payment in this case.
    #
    # @return [ActiveMerchant::Billing::Response] with +true+ if the void succeeded
    # @return [ActiveMerchant::Billing::Response] with +false+ if the void failed
    # @return [false] if it can't be voided at this time
    #
    def try_void(_payment)
      raise ::NotImplementedError,
        "You need to implement `try_void` for #{self.class.name}. In that " \
        'return a ActiveMerchant::Billing::Response object if the void succeeds '\
        'or `false|nil` if the void is not possible anymore. ' \
        'Solidus will refund the amount of the payment then.'
    end

    def store_credit?
      is_a? Spree::PaymentMethod::StoreCredit
    end

    protected

    # Represents the gateway class of this payment method
    #
    def gateway_class
      raise ::NotImplementedError, "You must implement gateway_class method for #{self.class}."
    end
  end
end
