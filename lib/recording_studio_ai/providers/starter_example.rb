# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    module StarterExample
      CLASS_CODE = <<~RUBY
        # lib/recording_studio_ai/providers/my_provider.rb
        module RecordingStudioAI
          module Providers
            class MyProvider < Base
              provider_key :my_provider

              def generate(request:, candidate:)
                response = client.complete(model: candidate.model, request: request)
                Result.new(text: response.fetch(:text).to_s)
              rescue StandardError => e
                raise unless ProviderError.expected?(e)

                failed_result(e)
              end

              # Add #stream and the batch methods only when your models support them.

              private

              def client
                configuration_client || MyClient.new(api_key: configuration_api_key)
              end
            end
          end
        end
      RUBY

      INITIALIZER_CODE = <<~RUBY
        # config/initializers/recording_studio_ai.rb
        RecordingStudioAI.configure do |config|
          config.singleton_class.class_eval do
            attr_accessor :my_provider_api_key, :my_provider_client
          end

          config.my_provider_api_key = ENV.fetch("MY_PROVIDER_API_KEY", nil)
          # Optional injected transport, handy in tests:
          # config.my_provider_client = MyClient.new(api_key: "test")
        end

        RecordingStudioAI.register_provider(
          :my_provider,
          RecordingStudioAI::Providers::MyProvider.new(configuration: RecordingStudioAI.configuration)
        )
      RUBY
    end
  end
end
