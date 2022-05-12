# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Google
  module Auth
    module OAuth2
      # OAuth 2.0 Token Exchange Spec.
      # This module defines a token exchange utility based on the `OAuth 2.0 Token
      # Exchange`_ spec. This will be mainly used to exchange external credentials
      # for GCP access tokens in workload identity pools to access Google APIs.
      # The implementation will support various types of client authentication as
      # allowed in the spec.
      # A deviation on the spec will be for additional Google specific options that
      # cannot be easily mapped to parameters defined in the RFC.
      # The returned dictionary response will be based on the `rfc8693 section 2.2.1`_
      # spec JSON response.
      # .. _OAuth 2.0 Token Exchange: https://tools.ietf.org/html/rfc8693
      # .. _rfc8693 section 2.2.1: https://tools.ietf.org/html/rfc8693#section-2.2.1
      class STSClient
        URLENCODED_HEADERS = {"Content-Type": "application/x-www-form-urlencoded"}.freeze


        def initialize options = {}
          @token_exchange_endpoint = options[:token_exchange_endpoint]
        end

        # Exchanges the provided token for another type of token based on the
        # rfc8693 spec
        #
        # options:
        #     connection Optional(Faraday connection): A callable used to make
        #         HTTP requests.
        #     grant_type (str): The OAuth 2.0 token exchange grant type.
        #     subject_token (str): The OAuth 2.0 token exchange subject token.
        #     subject_token_type (str): The OAuth 2.0 token exchange subject token type.
        #     resource (Optional[str]): The optional OAuth 2.0 token exchange resource field.
        #     audience (Optional[str]): The optional OAuth 2.0 token exchange audience field.
        #     scopes (Optional[Sequence[str]]): The optional list of scopes to use.
        #     requested_token_type (Optional[str]): The optional OAuth 2.0 token exchange requested
        #         token type.
        #     actor_token (Optional[str]): The optional OAuth 2.0 token exchange actor token.
        #     actor_token_type (Optional[str]): The optional OAuth 2.0 token exchange actor token type.
        #     additional_options (Optional[Mapping[str, str]]): The optional additional
        #         non-standard Google specific options.
        #     additional_headers (Optional[Mapping[str, str]]): The optional additional
        #         headers to pass to the token exchange endpoint.
        # Returns:
        #     Mapping[str, str]: The token exchange JSON-decoded response data containing
        #         the requested token and its expiration time.
        def exchange_token options = {}
          missing_required_opts = [:grant_type, :subject_token, :subject_token_type] - options.keys
          unless missing_required_opts.empty?
            raise ArgumentError, "Missing required options: #{missing_required_opts.join(', ')}"
          end

          c = options[:connection] || Faraday.default_connection

          headers = URLENCODED_HEADERS.dup.merge(options[:additional_headers] || {})

          request_body = {
            "grant_type": options[:grant_type],
            "audience": options[:audience],
            "scope": options[:scopes]&.join(' ') || [],
            "requested_token_type": options[:requested_token_type],
            "subject_token": options[:subject_token],
            "subject_token_type": options[:subject_token_type]
          }

          response = c.post(@token_exchange_endpoint, URI.encode_www_form(request_body), headers)

          if response.status != 200
            raise "Token exchange failed with status #{response.status}"
          end

          MultiJson.load response.body
        end
      end
    end
  end
end
