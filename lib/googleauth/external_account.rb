# Copyright 2015 Google, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "googleauth/oauth2/sts_client"

module Google
  # Module Auth provides classes that provide Google-specific authorization
  # used to access Google APIs.
  module Auth

    class ExternalAccountCredentials
      extend CredentialsLoader
      attr_reader :project_id
      attr_reader :quota_project_id

      # Create a ExternalAccountCredentials
      #
      # @param json_key_io [IO] an IO from which the JSON key can be read
      # @param scope [string|array|nil] the scope(s) to access
      def self.make_creds options = {}
        json_key_io, scope = options.values_at :json_key_io, :scope

        raise "a json file is required for external account credentials" unless json_key_io
        user_creds = read_json_key json_key_io

        AwsCredentials.new(
          audience: user_creds["audience"],
          scope: scope,
          subject_token_type: user_creds["subject_token_type"],
          token_url: user_creds["token_url"],
          credential_source: user_creds["credential_source"],
          service_account_impersonation_url: user_creds["service_account_impersonation_url"],
          region: ENV[CredentialsLoader::AWS_REGION_VAR] || ENV[CredentialsLoader::AWS_DEFAULT_REGION_VAR]
        )
      end

      # Reads the  fields from the
      # JSON key.
      def self.read_json_key json_key_io
        json_key = MultiJson.load json_key_io.read
        wanted = [
          "audience", "subject_token_type", "token_url", "credential_source", "service_account_impersonation_url"
        ]
        wanted.each do |key|
          raise "the json is missing the #{key} field" unless json_key.key? key
        end
        json_key
      end
    end

    class AwsCredentials
      AUTH_METADATA_KEY = :authorization
      STS_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
      STS_REQUESTED_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token"
      IAM_SCOPE = ["https://www.googleapis.com/auth/iam"]

      def initialize options = {}
        @audience = options[:audience]
        @scope = options[:scope] || IAM_SCOPE
        @subject_token_type = options[:subject_token_type]
        @token_url = options[:token_url]
        @credential_source = options[:credential_source] || {}
        @service_account_impersonation_url = options[:service_account_impersonation_url]

        @environment_id = @credential_source["environment_id"]
        @region_url = @credential_source["region_url"]
        @credential_source_url = @credential_source["url"]
        @regional_cred_verification_url = @credential_source["regional_cred_verification_url"]

        @region = options[:region] || region(options)
        @request_signer = AwsRequestSigner.new(@region)

        @expiry = nil
        @access_token = nil

        @sts_client = Google::Auth::OAuth2::STSClient.new(token_exchange_endpoint: @token_url)
      end

      def fetch_access_token! options = {}
        credentials = fetch_security_credentials options

        request_options = @request_signer.generate_signed_request(
          credentials,
          @regional_cred_verification_url.sub("{region}", @region),
          "POST"
        )

        request_headers = request_options[:headers]
        request_headers["x-goog-cloud-target-resource"] = @audience

        aws_signed_request = {
          headers: [],
          method: request_options[:method],
          url: request_options[:url]
        }
        aws_signed_request[:headers] = request_headers.keys.sort.map do |key|
          {key: key, value: request_headers[key]}
        end

        response = @sts_client.exchange_token(
          audience: @audience,
          grant_type: STS_GRANT_TYPE,
          subject_token: uri_escape(aws_signed_request.to_json),
          subject_token_type: @subject_token_type,
          scopes: @scope,
          requested_token_type: STS_REQUESTED_TOKEN_TYPE
        )
        # Extract the expiration time in seconds from the response and calculate the actual expiration time
        # and then save that to the expiry variable.
        @expiry = Time.now.utc + response["expires_in"].to_i
        @access_token = response["access_token"]
      end

      # Whether the id_token or access_token is missing or about to expire.
      def needs_access_token?
        @access_token.nil? || expires_within?(60)
      end

      def expires_within?(seconds)
        @expiry && @expiry - Time.now.utc < seconds
      end

      # Updates a_hash updated with the authentication token
      def apply! a_hash, opts = {}
        # fetch the access token there is currently not one, or if the client
        # has expired
        fetch_access_token! opts if needs_access_token?
        a_hash[AUTH_METADATA_KEY] = "Bearer #{@access_token}"
      end

      # Returns a clone of a_hash updated with the authentication token
      def apply a_hash, opts = {}
        a_copy = a_hash.clone
        apply! a_copy, opts
        a_copy
      end

      private

      def uri_escape(string)
        if string.nil?
          nil
        else
          CGI.escape(string.encode('UTF-8')).gsub('+', '%20').gsub('%7E', '~')
        end
      end

      # Retrieves the AWS security credentials required for signing AWS
      # requests from either the AWS security credentials environment variables
      # or from the AWS metadata server.
      def fetch_security_credentials options = {}
        env_aws_access_key_id = ENV[CredentialsLoader::AWS_ACCESS_KEY_ID_VAR]
        env_aws_secret_access_key = ENV[CredentialsLoader::AWS_SECRET_ACCESS_KEY_VAR]
        # This is normally not available for permanent credentials.
        env_aws_session_token = ENV[CredentialsLoader::AWS_SESSION_TOKEN_VAR]

        if env_aws_access_key_id && env_aws_secret_access_key
          return {
            access_key_id: env_aws_access_key_id,
            secret_access_key: env_aws_secret_access_key,
            session_token: env_aws_session_token
          }
        end

        role_name = fetch_metadata_role_name options
        credentials = fetch_metadata_security_credentials role_name, options

        return {
          access_key_id: credentials["AccessKeyId"],
          secret_access_key: credentials["SecretAccessKey"],
          session_token: credentials["Token"]
        }
      end

      # Retrieves the AWS role currently attached to the current AWS
      # workload by querying the AWS metadata server. This is needed for the
      # AWS metadata server security credentials endpoint in order to retrieve
      # the AWS security credentials needed to sign requests to AWS APIs.
      def fetch_metadata_role_name options = {}
        unless @credential_source_url
          raise "Unable to determine the AWS metadata server security credentials endpoint"
        end

        c = options[:connection] || Faraday.default_connection
        response = c.get @credential_source_url

        unless response.success?
          raise "Unable to determine the AWS role attached to the current AWS workload"
        end

        return response.body
      end

      # Retrieves the AWS security credentials required for signing AWS
      # requests from the AWS metadata server.
      def fetch_metadata_security_credentials role_name, options = {}
        c = options[:connection] || Faraday.default_connection

        response = c.get "#{@credential_source_url}/#{role_name}", {}, {"Content-Type": "application/json"}

        unless response.success?
          raise "Unable to fetch the AWS security credentials required for signing AWS requests"
        end

        return MultiJson.load response.body
      end

      # Region may already be set, if it is then it can just be returned
      def region options = {}
        unless @region
          raise "region_url or region must be set for external account credentials" unless @region_url

          c = options[:connection] || Faraday.default_connection
          @region ||= c.get(@region_url).body[..-2]
        end

        @region
      end
    end

    # Implements an AWS request signer based on the AWS Signature Version 4 signing process.
    # https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
    class AwsRequestSigner
      # Instantiates an AWS request signer used to compute authenticated signed
      # requests to AWS APIs based on the AWS Signature Version 4 signing process.
      # Args:
      #     region_name (str): The AWS region to use.
      def initialize region_name
        @region_name = region_name
      end

      # Generates the signed request for the provided HTTP request for calling
      # an AWS API. This follows the steps described at:
      # https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
      # Args:
      #     aws_security_credentials (Hash[str, str]): A dictionary containing
      #         the AWS security credentials.
      #     url (str): The AWS service URL containing the canonical URI and
      #         query string.
      #     method (str): The HTTP method used to call this API.
      # Returns:
      #     Hash[str, str]: The AWS signed request dictionary object.
      def generate_signed_request(aws_credentials, url, method, request_payload="")
        headers = {}

        uri = URI.parse url

        headers['host'] = uri.host

        if !uri.hostname || uri.scheme != "https"
          raise "Invalid AWS service URL"
        end

        service_name = uri.host.split(".").first

        datetime = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        date = datetime[0,8]

        headers['x-amz-date'] = datetime
        headers['x-amz-security-token'] = aws_credentials[:session_token] if aws_credentials[:session_token]

        content_sha256 = sha256_hexdigest(request_payload)

        canonical_req = canonical_request(method, uri, headers, content_sha256)
        sts = string_to_sign(datetime, canonical_req, service_name)

        # Authorization header requires everything else to be properly setup in order to be properly
        # calculated.
        headers['Authorization'] = [
          "AWS4-HMAC-SHA256",
          "Credential=#{credential(aws_credentials[:access_key_id], date, service_name)},",
          "SignedHeaders=#{headers.keys.sort.join(';')},",
          "Signature=#{signature(aws_credentials[:secret_access_key], date, sts, service_name)}"
        ].join(" ")

        {
          url: uri.to_s,
          headers: headers,
          method: method
        }
      end

      private

      def signature(secret_access_key, date, string_to_sign, service)
        k_date = hmac("AWS4" + secret_access_key, date)
        k_region = hmac(k_date, @region_name)
        k_service = hmac(k_region, service)
        k_credentials = hmac(k_service, 'aws4_request')

        hexhmac(k_credentials, string_to_sign)
      end

      def hmac(key, value)
        OpenSSL::HMAC.digest(OpenSSL::Digest.new('sha256'), key, value)
      end

      def hexhmac(key, value)
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), key, value)
      end

      def credential(access_key_id, date, service)
        "#{access_key_id}/#{credential_scope(date, service)}"
      end

      def credential_scope(date, service)
        [
          date,
          @region_name,
          service,
          'aws4_request',
        ].join('/')
      end

      def string_to_sign(datetime, canonical_request, service)

        [
          'AWS4-HMAC-SHA256',
          datetime,
          credential_scope(datetime[0,8], service),
          sha256_hexdigest(canonical_request)
        ].join("\n")
      end

      def host(uri)
        # Handles known and unknown URI schemes; default_port nil when unknown.
        if uri.default_port == uri.port
          uri.host
        else
          "#{uri.host}:#{uri.port}"
        end
      end

      def canonical_request(http_method, uri, headers, content_sha256)
        headers = headers.sort_by(&:first) # transforms to a sorted array of [key, value]

        [
          http_method,
          uri.path.empty? ? '/' : uri.path,
          build_canonical_querystring(uri.query || ''),
          headers.map { |k,v| "#{k}:#{v}\n" }.join, # Canonical headers
          headers.map(&:first).join(";"), # Signed headers
          content_sha256
        ].join("\n")
      end

      def sha256_hexdigest(string)
        OpenSSL::Digest::SHA256.hexdigest(string)
      end

      # Generates the canonical query string given a raw query string.
      # Logic is based on
      # https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
      # Code is from the AWS SDK for Ruby
      # https://github.com/aws/aws-sdk-ruby/blob/0ac3d0a393ed216290bfb5f0383380376f6fb1f1/gems/aws-sigv4/lib/aws-sigv4/signer.rb#L532
      def build_canonical_querystring(query)
        params = query.split('&')
        params = params.map { |p| p.match(/=/) ? p : p + '=' }

        params.each.with_index.sort do |a, b|
          a, a_offset = a
          b, b_offset = b
          a_name, a_value = a.split('=')
          b_name, b_value = b.split('=')
          if a_name == b_name
            if a_value == b_value
              a_offset <=> b_offset
            else
              a_value <=> b_value
            end
          else
            a_name <=> b_name
          end
        end.map(&:first).join('&')
      end
    end
  end
end
