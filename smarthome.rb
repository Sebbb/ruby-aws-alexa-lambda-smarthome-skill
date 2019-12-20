require 'json'
require "pp"
require 'time'
require "net/http"
require "uri"

def produce_event_response(event)
  {
    "event" => {
      "header" => {
        "namespace" => "Alexa",
        "name" => "Response",
        "messageId" => event["directive"]["header"]["messageId"],
        "correlationToken" => event["directive"]["header"]["correlationToken"],
        "payloadVersion" => "3"
      },
      "endpoint" => {
        "scope" => event["directive"]["endpoint"]["scope"],
        "endpointId" => event["directive"]["endpoint"]["endpointId"]
      },
      "payload" => {}
    },
    "context" => {
      "properties" => []
    }
  }
end

def lambda_handler(event:, context:)
  STDERR.puts event.inspect
  if event["directive"]["header"]["namespace"] == "Alexa.Discovery"
    token = event["directive"]["payload"]["scope"]["token"]
  else
    token = event["directive"]["endpoint"]["scope"]["token"]
  end
  
  profile = Oauth2.get_profile(token)
  raise unless profile["user_id"] == "amzn1.account.XXXXXXXXX" # let only me use this API

  case event["directive"]["header"]["namespace"]
  when "Alexa.PowerController"
    Management.action(id: event["directive"]["endpoint"]["endpointId"], method: event["directive"]["header"]["name"]=='TurnOn' ? 'on' : 'off')
    result = produce_event_response(event)

  when "Alexa.BrightnessController"
    if event["directive"]["header"]["name"]=='SetBrightness'
      Management.action(id: event["directive"]["endpoint"]["endpointId"], method: 'set', value: (event["directive"]["payload"]["brightness"].to_f/100*255).to_i)
      result = produce_event_response(event)
      result["context"]["properties"] = [
        {
          "namespace" => "Alexa.BrightnessController",
          "name" => "brightness",
          "value" => event["directive"]["payload"]["brightness"],
          "timeOfSample" => Time.now.iso8601,
          "uncertaintyInMilliseconds" => 1000
        }
      ]
    end
  when "Alexa.Discovery"
    discovered = Management.discover
    capabilities = {
      "power" => {
        "type" => "AlexaInterface",
        "interface" => "Alexa.PowerController",
        "version" => "3",
        "properties" => {
          "supported" => [
              {
                  "name" => "powerState"
              }
          ],
          "proactivelyReported" => false,
          "retrievable" => false
        }
      },
      "brightness" => {
        "type" => "AlexaInterface",
        "interface" => "Alexa.BrightnessController",
        "version" => "3",
        "properties" => {
          "supported" => [
              {
                  "name" => "brightness"
              }
          ],
          "proactivelyReported" => false,
          "retrievable" => false
        }
      }
    }

    endpoints = discovered["data"].map{|endpoint|
      next unless endpoint["capabilities"].all?{|capability| capabilities[capability]}
      {
        "endpointId" => endpoint["endpoint_id"],
        "manufacturerName" => "Seb",
        "description" => endpoint["friendly_name"],
        "friendlyName" => endpoint["friendly_name"],
        "displayCategories" => endpoint["display_categories"].map(&:upcase),
        "capabilities" => endpoint["capabilities"].map{|capability| capabilities[capability]}
      }
    }.compact

    result = {
      "event" => {
        "header" => {
          "namespace" => "Alexa.Discovery",
          "name" => "Discover.Response",
          "payloadVersion" => "3",
          "messageId" => event["directive"]["header"]["messageId"]
        },
        "payload" => {
          "endpoints" => endpoints
        }
      }
    }
  else
    raise "unknown:" + event.inspect
  end

  STDERR.print JSON.generate(result)
  result
end

class Management
  def self.post(params)
    uri = URI('https://.../connection/alexa')
    uri.query = URI.encode_www_form(params.merge({secret: 'XXX'}))
    res = Net::HTTP.post_form(uri, {})
    JSON.parse(res.body) if res.is_a?(Net::HTTPSuccess)
  end

  def self.discover
    post({ mode: 'discover' })
  end
  
  def self.action(id:, method:, value:nil)
    hash = {mode: 'action', id: id, method: method}
    hash[:value]=value if value
    post(hash)
  end
end

class Oauth2
  def self.get_profile(token)
    uri = URI('https://api.amazon.com/user/profile')
    params = { access_token: token}
    uri.query = URI.encode_www_form(params)
    res = Net::HTTP.get_response(uri)
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
  end
end

