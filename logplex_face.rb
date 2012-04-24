$stdout.sync = $stderr.sync = true

require "rubygems"
require "thread"
require "redis"
require "uri"
require "erb"

module LogplexFace 

  extend self

  HAPROXY_CONF = "haproxy.conf"
  REDIS_URL = ENV["LOGPLEX_STATS_REDIS_URL"] || raise("missing LOGPLEX_STATS_REDIS_URL")
  CLOUD = ENV['HEROKU_DOMAIN'] || raise("missing HEROKU_DOMAIN")
  VERSION = ENV['LOGPLEX_VERSION'] || ""

  @@logplex_instances = {}

  def compare(new_instances)
    if @@logplex_instances.keys.sort != new_instances.keys.sort
      log("update", "#{@@logplex_instances.inspect} to #{new_instances.inspect}")
      @@logplex_instances = new_instances
      write_file
      reload_config
    elsif !@@logplex_instances.eql?(new_instances)
      log("set weight", "#{@@logplex_instances.inspect} to #{new_instances.inspect}")
      new_instances.each do |ip,weight|
        set_weight(ip,weight) unless weight == @@logplex_instances[ip]
      end
      @@logplex_instances = new_instances
      write_file
    end
  end

  def log(event, data=nil)
    line = "#{Time.now} [#{event}]"
    line << " #{data}" if data
    $stdout.puts(line)
  end

  def write_file
    content = generate
    File.open(HAPROXY_CONF, "w") {|f| f.write(content) }
  end

  def reload_config
    log("restart", `restart haproxy`)
  end

  def set_weight(ip, weight)
    `echo "set weight logplextcp/#{ip} #{weight}" | socat unix-connect:/tmp/haproxy.sock stdio`
    `echo "set weight logplexsyslog/#{ip} #{weight}" | socat unix-connect:/tmp/haproxy.sock stdio`
    log("update tcp weight", `echo "get weight logplextcp/#{ip}" | socat unix-connect:/tmp/haproxy.sock stdio`.strip)
    log("update syslog weight", `echo "get weight logplexsyslog/#{ip}" | socat unix-connect:/tmp/haproxy.sock stdio`.strip)
    `echo "set weight logplexapi/#{ip} #{weight}" | socat unix-connect:/tmp/haproxy.sock stdio`
    log("update http weight", `echo "get weight logplexapi/#{ip}" | socat unix-connect:/tmp/haproxy.sock stdio`.strip)
  end

  def generate
    ERB.new(File.read("#{File.dirname(__FILE__)}/haproxy.conf.erb")).result(binding())
  end

  def poll
    log("init", "LogplexFace.poll")
    uri = URI.parse(REDIS_URL)
    redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.user)
    last_instances = {} # this is a failsafe to ensure consistent redis queries
    loop do
      new_instances = {}
      match = "redgrid:#{CLOUD}:#{VERSION}:*"
      redis.keys(match).each do |key|
        res = redis.hmget(key, "ip", "weight")
        ip = res[0]
        weight = res[1]
        new_instances[ip] = weight if weight
        new_instances[ip] = "100" unless weight
      end
      # last two redis queries must be identical before allowing config to be rewritten
      compare(new_instances) if last_instances == new_instances 
      last_instances = new_instances
      sleep(2)
    end
  end
end
