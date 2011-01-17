$stdout.sync = $stderr.sync = true

require "rubygems"
require "redis"
require "uri"
require "erb"

module LogplexFace 

  extend self

  HAPROXY_CONF = "haproxy.conf"
  REDIS_URL = ENV["LOGPLEX_CONFIG_REDIS_URL"] || raise("missing LOGPLEX_CONFIG_REDIS_URL")
  CLOUD = ENV['HEROKU_DOMAIN'] || raise("missing HEROKU_DOMAIN")

  @@logplex_instances = {}

  def compare(new_instances)
    unless @@logplex_instances.eql?(new_instances)
      log("update", "#{@@logplex_instances.inspect} to #{new_instances.inspect}")
      @@logplex_instances = new_instances
      write_file
    end
  end

  def log(event, data=nil)
    line = "timestamp=#{Time.now.to_i} [#{event}]"
    line << " #{data}" if data
    $stdout.puts(line)
  end

  def write_file
    content = generate
    File.open(HAPROXY_CONF, "w") {|f| f.write(content) }
    log("reload", `reload haproxy`)
  end

  def generate
    ERB.new(File.read("#{File.dirname(__FILE__)}/haproxy.conf.erb")).result(binding())
  end

  def poll
    log("init", "LogplexFace.poll")
    uri = URI.parse(REDIS_URL)
    redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.user)
    loop do
      new_instances = {}
      redis.keys("#{CLOUD}:alive:*").each do |key|
        ip = key.split(":").last
        weight = redis.get("#{CLOUD}:weight:#{ip}")
        new_instances[ip] = weight if weight
        new_instances[ip] = "100" unless weight
      end
      compare(new_instances)
      sleep(1)
    end
  end
end
