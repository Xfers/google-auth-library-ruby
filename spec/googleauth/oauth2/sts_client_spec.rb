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

spec_dir = File.expand_path File.join(File.dirname(__FILE__))
$LOAD_PATH.unshift spec_dir
$LOAD_PATH.uniq!

describe Google::Auth::OAuth2::STSClient do
  CLIENT_ID = "username"
  CLIENT_SECRET = "password"
  # Base64 encoding of "username:password"
  BASIC_AUTH_ENCODING = "dXNlcm5hbWU6cGFzc3dvcmQ="
  GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange".freeze
  RESOURCE = "https://api.example.com/".freeze
  AUDIENCE = "urn:example:cooperation-context".freeze
  SCOPES = ["scope1", "scope2"].freeze
  REQUESTED_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token".freeze
  SUBJECT_TOKEN = "HEADER.SUBJECT_TOKEN_PAYLOAD.SIGNATURE".freeze
  SUBJECT_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt".freeze
  ACTOR_TOKEN = "HEADER.ACTOR_TOKEN_PAYLOAD.SIGNATURE".freeze
  ACTOR_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:jwt".freeze
  TOKEN_EXCHANGE_ENDPOINT = "https://example.com/token.oauth2".freeze
  ADDON_HEADERS = {"x-client-version": "0.1.2"}.freeze
  ADDON_OPTIONS = {"additional": {"non-standard": ["options"], "other": "some-value"}}.freeze
  SUCCESS_RESPONSE = {
      "access_token": "ACCESS_TOKEN",
      "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
      "token_type": "Bearer",
      "expires_in": 3600,
      "scope": "scope1 scope2",
  }.freeze
  ERROR_RESPONSE = {
      "error": "invalid_request",
      "error_description": "Invalid subject token",
      "error_uri": "https://tools.ietf.org/html/rfc6749",
  }.freeze

  describe 'without client authentication' do
    it 'should successfully exchange a token with only required parameters' do
      client = STSClient.new({token_exchange_endpoint: TOKEN_EXCHANGE_ENDPOINT})

      stub_request(:post, TOKEN_EXCHANGE_ENDPOINT)
          .with(

      response = client.exchange_token({
        grant_type: GRANT_TYPE,
        subject_token: SUBJECT_TOKEN,
        subject_token_type: SUBJECT_TOKEN_TYPE,
        audience: AUDIENCE,
        requested_token_type: REQUESTED_TOKEN_TYPE
      })

      expect(response.access_token).to eq(SUCCESS_RESPONSE["access_token"])
    end
  end
