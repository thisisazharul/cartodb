module Carto
  module Api
    module Public
      class DataObservatoryController < Carto::Api::Public::ApplicationController
        include Carto::Api::PagedSearcher
        extend Carto::DefaultRescueFroms

        ssl_required

        before_action :load_user
        before_action :load_filters, only: [:subscriptions]
        before_action :load_id, only: [:subscription_info, :subscribe, :unsubscribe]
        before_action :load_type, only: [:subscription_info, :subscribe]
        before_action :check_api_key_permissions
        before_action :check_do_enabled, only: [:subscription_info, :subscriptions]

        setup_default_rescues

        respond_to :json

        BIGQUERY_KEY = 'bq'.freeze
        VALID_TYPES = %w(dataset geography).freeze
        DATASET_REGEX = /[\w\-]+\.[\w\-]+\.[\w\-]+/.freeze
        VALID_ORDER_PARAMS = %i(id table dataset project type).freeze
        METADATA_FIELDS = %i(id estimated_delivery_days subscription_list_price tos tos_link licenses licenses_link
                             rights type).freeze
        TABLES_BY_TYPE = { 'dataset' => 'datasets', 'geography' => 'geographies' }.freeze
        REQUIRED_METADATA_FIELDS = %i(available_in estimated_delivery_days subscription_list_price).freeze
        DEFAULT_DELIVERY_DAYS = 3.0

        def token
          response = Cartodb::Central.new.get_do_token(@user.username)
          render(json: response)
        end

        def subscriptions
          available_subscriptions = bq_subscriptions.select { |dataset| Time.parse(dataset['expires_at']) > Time.now }
          response = present_subscriptions(available_subscriptions)
          render(json: { subscriptions: response })
        end

        def subscription_info
          response = present_metadata(subscription_metadata)

          render(json: response)
        end

        def subscribe
          metadata = subscription_metadata

          instant_licensing_available?(metadata) ? instant_license(metadata) : regular_license(metadata)

          response = present_metadata(metadata)
          render(json: response)
        end

        def instant_licensing_available?(metadata)
          @user.has_feature_flag?('do-instant-licensing') &&
            REQUIRED_METADATA_FIELDS.all? { |field| metadata[field].present? } &&
            metadata[:estimated_delivery_days].zero?
        end

        def instant_license(metadata)
          licensing_service = Carto::DoLicensingService.new(@user.username)
          licensing_service.subscribe(license_info(metadata))
        end

        def regular_license(metadata)
          DataObservatoryMailer.user_request(@user, metadata[:id], metadata[:name]).deliver_now
          DataObservatoryMailer.carto_request(@user, metadata[:id], metadata[:estimated_delivery_days]).deliver_now
        end

        def unsubscribe
          Carto::DoLicensingService.new(@user.username).unsubscribe(@id)

          head :no_content
        end

        private

        def load_user
          @user = Carto::User.find(current_viewer.id)
        end

        def load_filters
          _, _, @order, @direction = page_per_page_order_params(
            VALID_ORDER_PARAMS, default_order: 'id', default_order_direction: 'asc'
          )
          load_type(required: false)
        end

        def load_id
          @id = params[:id]
          raise ParamInvalidError.new(:id) unless @id =~ DATASET_REGEX
        end

        def load_type(required: true)
          @type = params[:type]
          return if @type.nil? && !required

          raise ParamInvalidError.new(:type, VALID_TYPES.join(', ')) unless VALID_TYPES.include?(@type)
        end

        def check_api_key_permissions
          api_key = Carto::ApiKey.find_by_token(params["api_key"])
          raise UnauthorizedError unless api_key&.master? || api_key&.data_observatory_permissions?
        end

        def check_do_enabled
          Cartodb::Central.new.check_do_enabled(@user.username)
        end

        def rescue_from_central_error(exception)
          render_jsonp({ errors: exception.errors }, 500)
        end

        def bq_subscriptions
          redis_key = "do:#{@user.username}:datasets"
          redis_value = $users_metadata.hget(redis_key, BIGQUERY_KEY) || '[]'
          JSON.parse(redis_value)
        end

        def present_subscriptions(subscriptions)
          central_subscriptions = Cartodb::Central.new.get_do_datasets(username: @user.username)

          enriched_subscriptions = subscriptions.map do |subscription|
            qualified_id = subscription['dataset_id']
            created_at, expires_at, status = nil

            central_subscriptions.each do |central_subscription|
              if central_subscription['dataset_id'] == qualified_id
                created_at = central_subscription['created_at']
                expires_at = central_subscription['expires_at']
                status = central_subscription['status']
              end
            end

            project, dataset, table = qualified_id.split('.')
            # FIXME: better save the type in Redis or look for it in the metadata tables
            type = table.starts_with?('geography') ? 'geography' : 'dataset'

            sync_service = DoSyncService.new(@user)
            sync_info = sync_service.sync(qualified_id) || {}

            { project: project, dataset: dataset, table: table, id: qualified_id, type: type,
              created_at: created_at,
              expires_at: expires_at,
              status: status,
              sync_status: sync_info[:sync_status],
              unsyncable_reason: sync_info[:unsyncable_reason],
              unsynced_errors: sync_info[:unsynced_errors],
              synced_warnings: sync_info[:synced_warnings],
              sync_table: sync_info[:sync_table],
              sync_table_id: sync_info[:sync_table_id],
              synchronization_id: sync_info[:synchronization_id],
              estimated_size: sync_info[:estimated_size],
              estimated_row_count: sync_info[:estimated_row_count] }
          end
          enriched_subscriptions.select! { |subscription| subscription[:type] == @type } if @type
          ordered_subscriptions = enriched_subscriptions.sort_by { |subscription| subscription[@order] }
          @direction == :asc ? ordered_subscriptions : ordered_subscriptions.reverse
        end

        def present_metadata(metadata)
          metadata[:estimated_delivery_days] = present_delivery_days(metadata[:estimated_delivery_days])
          metadata.slice(*METADATA_FIELDS)
        end

        def present_delivery_days(delivery_days)
          return DEFAULT_DELIVERY_DAYS if delivery_days&.zero? && !@user.has_feature_flag?('do-instant-licensing')

          delivery_days
        end

        def subscription_metadata
          connection = Carto::Db::Connection.do_metadata_connection()

          query = "SELECT *, '#{@type}' as type FROM #{TABLES_BY_TYPE[@type]} WHERE id = '#{@id}'"
          result = connection.execute(query).first
          raise Carto::LoadError.new("No metadata found for #{@id}") unless result

          cast_metadata_result(result)
        end

        def cast_metadata_result(metadata)
          metadata = metadata.symbolize_keys
          metadata[:subscription_list_price] = metadata[:subscription_list_price]&.to_f
          metadata[:estimated_delivery_days] = metadata[:estimated_delivery_days]&.to_f
          metadata[:available_in] = metadata[:available_in].delete('{}').split(',') unless metadata[:available_in].nil?
          metadata
        end

        def license_info(metadata)
          {
            dataset_id: metadata[:id],
            available_in: metadata[:available_in],
            price: metadata[:subscription_list_price],
            expires_at: Time.now.round + 1.year
          }
        end
      end
    end
  end
end
