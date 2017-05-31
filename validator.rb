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
      if !response["content-type"].include?("application/json")
        raise FeedError.new("error", "Content-Type was #{response['content-type']}. It should be application/json.")
      end
    elsif response.is_a?(Net::HTTPRedirection)
      location = response["location"]
      s = download_feed(location, limit - 1)
    elsif response.is_a?(Net::HTTPNotFound)
      raise FeedError.new("error", "404. No feed was found at this URL.")
    elsif response.is_a?(Net::HTTPRequestTimeOut) || response.is_a?(Net::HTTPGatewayTimeOut)
      raise FeedError.new("error", "Timeout downloading the feed.")
    else
      logger.info "Feed: Unknown error #{response.code} #{response.message}, #{response.class.name}"
      raise FeedError.new("error", "Unknown error #{response.code} #{response.message}, #{response.class.name}.")
    end
  rescue FeedError => e
    raise e
  rescue Exception => e
    logger.info "Feed: Unknown exception #{e.class.name}"
    raise FeedError.new("error", "Unknown exception #{e.class.name}.")
  end
      
  return s
end

get '/' do
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

      formatter = Rouge::Formatters::HTMLInline.new(Rouge::Themes::Base16.new)
      lexer = Rouge::Lexers::JSON.new
      @json = formatter.format(lexer.lex(JSON.pretty_generate(response_json)))

      results = JSON::Validator.fully_validate(JSON_SCHEMA, response_json)
      for result in results
        cleaned = result
        cleaned = cleaned.gsub("The property '#/' ", "The top-level object ")
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)' /, 'The "\1" field ')
        cleaned = cleaned.gsub(/The property '#\/([a-z]*)\/([0-9]*)' /, 'The "\1" array (index \2) ')
        cleaned = cleaned.gsub(/ in schema (.*)/, '.')
        @errors << FeedError.new("error", cleaned)
      end      
    rescue JSON::ParserError => e
      @errors << FeedError.new("error", "JSON could not be parsed. #{e.message}.")
    rescue FeedError => e
      @errors << e
    end
  end
  
  erb :index
end
