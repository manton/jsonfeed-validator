require 'sinatra'
require 'net/http'
require 'json-schema'
require 'rouge'

JSON_SCHEMA = JSON.parse(IO.read(settings.root + "/config/schema.json"))

class FeedError < Exception
  attr_accessor :type
  attr_accessor :message

  def initialize(type, message)
    @type = type
    @message = message
  end
end

def download_feed(jsonfeed_url, limit = 5)
  if limit == 0
    raise FeedError.new("error", "Too many redirects.")
  end

  s = ""

  begin
    uri = URI(jsonfeed_url)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "JSONFeedValidator/1.0"

    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 30, read_timeout: 30, use_ssl: (uri.scheme == "https")) do |http|
      http.request(req)
    end

    if response.is_a?(Net::HTTPSuccess)
      s = response.body
      content_type = response["content-type"]
      if !content_type || (!content_type.include?("application/json") && !content_type.include?("application/feed+json"))
        raise FeedError.new("error", "Content-Type was #{response['content-type'] || "not sent"}. It should be application/feed+json.")
      end
    elsif response.is_a?(Net::HTTPRedirection)
      location = response["location"]
      s = download_feed(location, limit - 1)
    elsif response.is_a?(Net::HTTPNotFound)
      raise FeedError.new("error", "404 not found. No feed was found at this URL.")
    elsif response.is_a?(Net::HTTPRequestTimeOut) || response.is_a?(Net::HTTPGatewayTimeOut)
      raise FeedError.new("error", "Timeout downloading the feed.")
    else
      raise FeedError.new("error", "Unknown error #{response.code} #{response.message}, #{response.class.name}.")
    end
  rescue FeedError => e
    raise e
  rescue Exception => e
    raise FeedError.new("error", "Unknown exception #{e.class.name}.")
  end

  return s
end

def check_warnings(json)
  warnings = []

  if !["https://jsonfeed.org/version/1", "https://jsonfeed.org/version/1.1"].include? json["version"]
    warnings << "The \"version\" field should have the value: https://jsonfeed.org/version/1 or https://jsonfeed.org/version/1.1"
  end

  if json["home_page_url"].nil?
    warnings << "The \"home_page_url\" field is missing. It is strongly recommended, but not required."
  end

  if json["feed_url"].nil?
    warnings << "The \"feed_url\" field is missing. It is strongly recommended, but not required."
  end

  i = 0
  for item in json["items"].to_a
    if item["date_published"].nil?
#      warnings << "The items array (index #{i}) is missing the \"date_published\" field. It is strongly recommended, but not required."
    end
    i = i + 1
  end

  return warnings
end

get '/' do
  format = params[:format] || "html"

  @url = params[:url].to_s
  @errors = []
  @json = ""

  if @url.length > 0
    begin
      if !@url.include?("http")
        @url = "http://" + @url
      end

      s = download_feed(@url)
      response_json = JSON.parse(s)

      formatter = Rouge::Formatters::HTML.new(Rouge::Themes::Github.new)
      lexer = Rouge::Lexers::JSON.new
      @json = formatter.format(lexer.lex(JSON.pretty_generate(response_json)))

      results = JSON::Validator.fully_validate(JSON_SCHEMA, response_json)
      for result in results
        cleaned = result
        cleaned = cleaned.gsub("The property '#/' ", "The top-level object ")
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)' /, 'The "\1" field ')
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)\/([0-9]*)' /, 'The "\1" array (index \2) ')
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)\/([0-9]*)\/([a-z]*)\/([a-z]*)' /, 'The "\4" field in "\3" ("\1" array, index \2) ')
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)\/([0-9]*)\/([a-z]*)\/([0-9]*)' /, 'The object in "\3" (index \4, from array "\1" index \2) ')
        cleaned = cleaned.gsub('- allOf #0:', '')
        cleaned = cleaned.gsub(/ in schema (.*)/, '.')
        @errors << FeedError.new("error", cleaned)
      end

      warnings = check_warnings(response_json)
      for w in warnings
        @errors << FeedError.new("warning", w)
      end
    rescue JSON::ParserError => e
      @errors << FeedError.new("error", "JSON could not be parsed. #{e.message}.")
    rescue FeedError => e
      @errors << e
    end
  end

  case format
  when "json"
    content_type :json
    {
      valid: (@url.length > 0 && @errors.size == 0),
      errors: @errors.map { |error| { error.type.capitalize.to_s => e.message } }
    }.to_json
  else
    erb :index
  end
end
