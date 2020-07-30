# frozen_string_literal: true

require "net/http"
require "net/https"
require "uri"
require "yajl/json_gem"
require "base64"
require "time"

class ArcK8sClusterIdentity

  @@cluster_config_crd_api_version = "clusterconfig.azure.com/v1beta1"
  @@cluster_identity_resource_name = "container-insights-clusteridentityrequest"
  @@cluster_identity_resource_namespace = "azure-arc"
  @@cluster_identity_token_secret_namespace = "azure-arc"
  @@crd_resource_uri_template = "%{kube_api_server_url}/apis/%{cluster_config_crd_api_version}/namespaces/%{cluster_identity_resource_namespace}/azureclusteridentityrequests/%{cluster_identity_resource_name}"
  @@secret_resource_uri_template = "%{kube_api_server_url}/api/v1/namespaces/%{cluster_identity_token_secret_namespace}/secrets/%{token_secret_name}"
  @@azure_monitor_custom_metrics_audience = "https://monitoring.azure.com/"
  @@cluster_identity_request_kind = "AzureClusterIdentityRequest"

  def initialize
    @token_expiry_time = Time.now
    @cached_access_token = String.new
    @token_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    @cert_file_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    @kube_api_server_url = get_kube_api_server_url
    @http_client = get_http_client
    @service_account_token = get_service_account_token
  end

  def get_token_from_secret(token_secret_name, token_secret_data_name)
    token = nil
    begin
      secret_request_uri = @@secret_resource_uri_template % {
        kube_api_server_url: @kube_api_server_url,
        cluster_identity_token_secret_namespace: @@cluster_identity_token_secret_namespace,
        token_secret_name: token_secret_name,
      }
      get_request = Net::HTTP::Get.new(secret_request_uri)
      get_request["Authorization"] = "Bearer #{@service_account_token}"
      $log.info "Making GET request to #{secret_request_uri} @ #{Time.now.utc.iso8601}"
      get_response = @http_client.request(get_request)
      $log.info "Got response of #{get_response.code} for #{secret_request_uri} @ #{Time.now.utc.iso8601}"
      if get_response.code.to_i == 200
        token_secret = JSON.parse(get_response.body)["data"]
        cluster_identity_token = token_secret[token_secret_data_name]
        token = Base64.decode64(cluster_identity_token)
      end
    rescue => err
      $log.warn ("get_token_from_secret API call failed: #{err}")
    end
    return token
  end

  def get_token_reference_from_crd()
    tokenReference = {}
    begin
      crd_request_uri = @@crd_resource_uri_template % {
        kube_api_server_url: @kube_api_server_url,
        cluster_config_crd_api_version: @@cluster_config_crd_api_version,
        cluster_identity_resource_namespace: @@cluster_identity_resource_namespace,
        cluster_identity_resource_name: @@cluster_identity_resource_name,
      }
      get_request = Net::HTTP::Get.new(crd_request_uri)
      get_request["Authorization"] = "Bearer #{@service_account_token}"
      $log.info "Making GET request to #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      get_response = @http_client.request(get_request)
      $log.info "Got response of #{get_response.code} for #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      if get_response.code.to_i == 200
        status = JSON.parse(get_response.body)["status"]
        tokenReference["expirationTime"] = status["expirationTime"]
        tokenReference["secretName"]= status["tokenReference"]["secretName"]
        tokenReference["dataName"] = status["tokenReference"]["dataName"]
      end
    rescue => err
      $log.warn ("get_token_reference_from_crd call failed: #{err}")
    end
    return tokenReference
  end

  def renew_near_expiry_token()
    begin
      crd_request_uri = @@crd_resource_uri_template % {
        kube_api_server_url: @kube_api_server_url,
        cluster_config_crd_api_version: @@cluster_config_crd_api_version,
        cluster_identity_resource_namespace: @@cluster_identity_resource_namespace,
        cluster_identity_resource_name: @@cluster_identity_resource_name,
      }
      get_request = Net::HTTP::Get.new(crd_request_uri)
      get_request["Authorization"] = "Bearer #{@service_account_token}"
      $log.info "Making GET request to #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      get_response = @http_client.request(get_request)
      $log.info "Got response of #{get_response.code} for #{crd_request_uri} @ #{Time.now.utc.iso8601}"
      if get_response.code.to_i == 404 # NOT found
        #POST
        update_request = Net::HTTP::Post.new(crd_request_uri)
        update_request["Content-Type"] = "application/json"
      elsif get_response.code.to_i == 200 # Update == Patch
        #PATCH
        update_request = Net::HTTP::Patch.new(crd_request_uri)
        update_request["Content-Type"] = "application/merge-patch+json"
      end
      update_request["Authorization"] = "Bearer #{@service_account_token}"
      update_request_body = get_update_request_body
      update_request.body = update_request_body.to_json
      update_response = @http_client.request(update_request)
      $log.info "Got response of #{update_response.code} for #{crd_request_uri} @ #{Time.now.utc.iso8601}"
    rescue => err
      $log.warn ("renew_near_expiry_token call failed: #{err}")
    end
  end

  def get_cluster_identity_token()
    begin
      # get the cluster msi identity token either if its empty or near expirty. Token is valid 24 hrs.
      if @cached_access_token.to_s.empty? || (Time.now + 60 * 60 > @token_expiry_time) # Refresh token 1 hr from expiration
          # renew the token if its near expiry
          if !@cached_access_token.to_s.empty? && (Time.now + 60 * 60 > @token_expiry_time)
            renew_near_expiry_token
            # sleep 30 seconds to get the renewed token  available
            sleep 30
          end
          tokneReference = get_token_reference_from_crd
          if !tokneReference.nil? && !tokneReference.empty?
            @token_expiry_time = Time.parse(tokneReference["expirationTime"])
            token_secret_name = tokneReference["secretName"]
            token_secret_data_name = tokneReference["dataName"]
            # get the token from secret
            token = get_token_from_secret(token_secret_name, token_secret_data_name)
            if !token.nil?
              @cached_access_token = token
            else
              $log.warn ("got token nil from secret: #{@token_secret_name}")
            end
          end
      end
    rescue => err
      $log.warn ("get_cluster_identity_token failed: #{err}")
    end
    return @cached_access_token
  end

  private
  def get_service_account_token()
    begin
      if File.exist?(@token_file_path) && File.readable?(@token_file_path)
        token_str = File.read(@token_file_path).strip
        return token_str
      else
        $log.info ("Unable to read token string from #{@token_file_path}")
        return nil
      end
    end
  end

  def get_http_client()
    kube_api_server_url = get_kube_api_server_url
    base_api_server_url = URI.parse(kube_api_server_url)
    http = Net::HTTP.new(base_api_server_url.host, base_api_server_url.port)
    http.use_ssl = true
    if !File.exist?(@cert_file_path)
      raise "#{@cert_file_path} doesnt exist"
    else
      http.ca_file = @cert_file_path
    end
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    return http
  end

  def get_kube_api_server_url
    if ENV["KUBERNETES_SERVICE_HOST"] && ENV["KUBERNETES_PORT_443_TCP_PORT"]
      return "https://#{ENV["KUBERNETES_SERVICE_HOST"]}:#{ENV["KUBERNETES_PORT_443_TCP_PORT"]}"
    else
      $log.warn ("Kubernetes environment variable not set KUBERNETES_SERVICE_HOST: #{ENV["KUBERNETES_SERVICE_HOST"]} KUBERNETES_PORT_443_TCP_PORT: #{ENV["KUBERNETES_PORT_443_TCP_PORT"]}. Unable to form resourceUri")
      return nil
    end
  end

  def get_update_request_body
    body = {}
    body["apiVersion"] = @@cluster_config_crd_api_version
    body["kind"] = @@cluster_identity_request_kind
    body["metadata"] = {}
    body["metadata"]["name"] = @@cluster_identity_resource_name
    body["metadata"]["namespace"]  = @@cluster_identity_resource_namespace
    body["spec"] = {}
    body["spec"]["audience"] = @@azure_monitor_custom_metrics_audience
    return body
  end

end