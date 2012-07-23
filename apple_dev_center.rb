#!/usr/bin/ruby
require 'rubygems'
require 'optparse'
require 'mechanize'
require 'json'
require 'yaml'
require 'encrypted_strings'
require 'logger'

INSTALL_DIR = File.dirname($0)

class Profile
  attr_accessor :uuid, :blob_id, :type, :name, :appid, :statusXcode, :download_url
  def to_json(*a) {
      'uuid' => uuid,
      'type' => type,
      'name' => name,
      'appid' => appid,
      'statusXcode' => statusXcode
    }.to_json(*a)
  end
end # class Profile

class Certificate
  attr_accessor :displayId, :type, :name, :exp_date, :profile, :status, :download_url
  def to_json(*a) {
      'displayId' => displayId,
      'type' => type,
      'name' => name,
      'exp_date' => exp_date,
      'status' => status,
      'profile' => profile
    }.to_json(*a)
  end
end # class Certificate

class Device
  attr_accessor :udid, :name
  def to_json(*a) {
      'udid' => udid,
      'name' => name
    }.to_json(*a)
  end
end # class Device

class AppleDeveloperCenter
  def initialize(options)
    @options = options
    @agent = Mechanize.new()
    @agent.user_agent_alias = 'Mac Safari'
    @agent.pluggable_parser.default = Mechanize::File
    if not @options[:logfile].nil?
      @agent.log = Logger.new(@options[:logfile])
    end
    
    # Set proxy if environment variable 'https_proxy' is set.
    proxy_regex = /:\/\/(.[^:]*):(\d*)/
    if ENV['https_proxy'] != nil && ENV['https_proxy'].match(proxy_regex) 
      @agent.set_proxy(Regexp.last_match(1), Regexp.last_match(2))
    end
    
    @apple_cert_url = "http://www.apple.com/appleca/AppleIncRootCertificate.cer"
    @profile_urls = {}
#    @profile_urls[:development] = "https://developer.apple.com/ios/manage/provisioningprofiles/index.action"
    @profile_urls[:development] = "https://developer.apple.com/ios/my/provision/index.action"
    @profile_urls[:distribution] = "https://developer.apple.com/ios/manage/provisioningprofiles/viewDistributionProfiles.action"
    @certificate_urls = {}
    @certificate_urls[:development] = "https://developer.apple.com/ios/manage/certificates/team/index.action"
    @certificate_urls[:distribution] = "https://developer.apple.com/ios/manage/certificates/team/distribute.action"
    @devices_url = "https://developer.apple.com/ios/manage/devices/index.action"
  end
  
  def load_page_or_login(url)
    page = @agent.get(url)

    # Log in to ADMC if we're presented with a login form.
    form = page.form_with(:name => 'appleConnectForm')
    if form
      info "Logging in with Apple ID '#{@options[:login]}'."
      form.theAccountName = @options[:login]
      form.theAccountPW = @options[:passwd]
      form.submit
      page = @agent.get(url)
    end
    page

    # Select a team if you belong to multiple teams.
    form = page.form_with(:name => 'saveTeamSelection')
    if form
      info "Selecting team '#{@options[:teamid]}'."
      team_list = form.field_with(:name => 'memberDisplayId')
      team_option = team_list.option_with(:value => @options[:teamid])
      team_option.select
      btn = form.button_with(:name => 'action:saveTeamSelection!save')
      form.click_button(btn)
      page = @agent.get(url)
    end
    page
  end

  def read_profiles(page, type)
    profiles = []
    # Format each row as 'name,udid'.
    rows = page./('//table/tbody/tr')
    rows.each do |row|
      begin
        p = Profile.new()
        p.type = type
        p.name = row./('td.profile a').text
        p.appid = row./('td.appid').text
        p.statusXcode = row./('td.statusXcode').text.strip.split("\n")[0]
        p.download_url = row./('td.action a').attribute('href').to_s
        p.blob_id = p.download_url.split("=")[1]
        profiles << p
      rescue NoMethodError
      end
    end
    profiles
  end  

  def read_all_profiles()
    all_profiles = []
    @profile_urls.each { |type, url|
      info("Fetching #{type} profiles.")
      page = load_page_or_login(url)
      all_profiles.concat(read_profiles(page, type))
    } 
    all_profiles
  end

  def read_certificates_distribution(page, type)
    certs = []
    # Format each row as 'name,udid'.
    rows = page.parser.xpath('//div[@class="nt_multi"]/table/tbody/tr')
    rows.each do |row|
      last_elt = row.at_xpath('td[@class="action last"]')
      if last_elt.nil?
        msg_elt = row.at_xpath('td[@colspan="4"]/span')
        if !msg_elt.nil?
          info("-->#{msg_elt.text}")
        end
        next
      end
      next if last_elt.at_xpath('form').nil?
      c = Certificate.new()
      # :displayId, :type, :name, :exp_date, :profiles, :status, :download_url
      c.download_url = last_elt.at_xpath('a/@href')
      c.displayId = c.download_url.to_s.split("certDisplayId=")[1]
      c.type = type
      c.name = row.at_xpath('td[@class="name"]/a').text
      c.exp_date = row.at_xpath('td[@class="expdate"]').text.strip
      # One certificate can be mapped to several profiles.
      c.profile = row.at_xpath('td[@class="profile"]').text.strip
      c.status = row.at_xpath('td[@class="status"]').text.strip
      certs << c
    end
    certs
  end
  
  def read_certificates_development(page, type)
    certs = []
    # Format each row as name,udid  
    rows = page.parser.xpath('//div[@class="nt_multi"]/table/tbody/tr')
    rows.each do |row|
      last_elt = row.at_xpath('td[@class="last"]')
      next if last_elt.at_xpath('form').nil?
      c = Certificate.new()
      # :displayId, :type, :name, :exp_date, :profiles, :status, :download_url
      c.download_url = last_elt.at_xpath('a/@href')
      c.displayId = c.download_url.to_s.split("certDisplayId=")[1]
      c.type = type
      c.name = row.at_xpath('td[@class="name"]/div/p').text
      c.exp_date = row.at_xpath('td[@class="date"]').text.strip
      # One certificate can be mapped to several profiles.
      c.profile = row.at_xpath('td[@class="profiles"]').text.strip
      c.status = row.at_xpath('td[@class="status"]').text.strip
      certs << c
    end
    certs
  end  

  def read_all_certificates()
    all_certs = []
    info("Fetching development certificates.")
    page = load_page_or_login(@certificate_urls[:development])    
    all_certs.concat(read_certificates_development(page, :development))
    info("Fetching distribution certificates")
    page = load_page_or_login(@certificate_urls[:distribution])    
    all_certs.concat(read_certificates_distribution(page, :distribution))
    all_certs
  end

  def read_devices()
    page = load_page_or_login(@devices_url)
  
    info("Fetching devices.")
    devices = []
    rows = page.parser.xpath('//fieldset[@id="fs-0"]/table/tbody/tr')
    rows.each do |row|
      d = Device.new()
      d.name = row.at_xpath('td[@class="name"]/span/text()')
      d.udid = row.at_xpath('td[@class="id"]/text()')
      devices << d
    end
    devices
  end

  def fetch_site_data()
    site = {}
    @apple_cert_file = "#{@options[:dl_dir]}/AppleIncRootCertificate.cer"
    if not File.exists?(@apple_cert_file)
      @agent.get(@apple_cert_url).save(@apple_cert_file)
    end

    site[:devices] = read_devices()
    site[:profiles] = read_all_profiles()
    site[:certificates] = read_all_certificates()

    download_profiles(site[:profiles], @options[:dl_dir], @options[:profile_filename])
    download_certificates(site[:certificates], @options[:dl_dir])
    
    site
  end
  
  # Return the UUID of the specified mobile provisioning file.
  def pp_uuid(ppfile)
    # FIXME extract script into a reusable ruby library    
    uuid = `#{INSTALL_DIR}/mobileprovisioning.rb #{ppfile} -c #{@apple_cert_file} -d UUID`
    # Strip trailing '\n, \r, \r\n'.
    uuid = uuid.chomp()
    uuid
  end
  
  def download_profiles(profiles, dl_dir, profile_filename)
    profiles.each do |p|
      filename = "#{dl_dir}/#{p.blob_id}.mobileprovision"
      info("Downloading #{p.type} profile #{p.blob_id}.")
      @agent.get(p.download_url).save(filename)
      uuid = pp_uuid(filename)
      p.uuid = uuid
      if profile_filename == :uuid
        basename = p.uuid
      else
        basename = p.name
      end
      newfilename = "#{dl_dir}/#{basename}.mobileprovision"
      File.rename(filename, "#{newfilename}")
      info("Saved #{p.type} profile #{p.blob_id} (UUID='#{p.uuid}', NAME='#{p.name}') to '#{newfilename}'.")
    end
  end

  def download_certificates(certs, dl_dir)
    certs.each do |c|
      filename = "#{dl_dir}/#{c.displayId}.cer"
      info("Downloading #{c.type} certificate #{c.displayId}.")
      @agent.get(c.download_url).save(filename)
      info("Saved #{c.type} certificate #{c.displayId} (NAME='#{c.name}') to '#{filename}'.")
    end
  end
end # class AppleDeveloperCenter

def info(message)
  puts message
end

def parse_config(options)
  config = YAML::load_file(options[:config_file])
  login_to_fetch = options[:login]
  if login_to_fetch.nil? 
    login_to_fetch = config['default']
    options[:login] = login_to_fetch
  end
  account = config['accounts'].select { |a| a['login'] == login_to_fetch }[0]
  secret_key = options[:secretKey].nil? ? "" : options[:secretKey]
  encrypted = account['password']
  decrypted = encrypted.decrypt(:symmetric, :password => secret_key)
  options[:passwd] = decrypted
  options[:teamid] = account['teamid']
end

def parse_command_line(args)
  options = {}
  opts = OptionParser.new { |opts|
    opts.banner = "Usage: #{File.basename($0)} options\n" + 
      "Download certificates and profiles from Apple's Developer Member Center (ADMC) to current dir."
    opts.separator "Mandatory options:"

    options[:login] = nil
    opts.on('-u', '--user APPLEID', "ADMC login (aka Apple ID).") do |login|
      options[:login] = login
    end

    options[:passwd] = nil
    opts.on('-p', '--password PASSWORD', "ADMC password.") do |passwd|
      options[:passwd] = passwd
    end

    options[:config_file] = nil
    opts.on('-c', '--config FILE', "Fetch authentication credentials from FILE.") do |config_file|
      options[:config_file] = config_file
      if not File.exists?(options[:config_file])
        raise OptionParser::InvalidArgument, "Specified file '#{config_file}' doesn't exist."
      end
    end

    opts.separator "Optional options:"

    options[:teamid] = nil
    opts.on('-t', '--teamid TEAMID', 
            "Team ID from Apple's Multiple Developer Programs.") do |teamid|
      options[:teamid] = teamid
    end

    options[:profile_filename] = :uuid
    opts.on('-n', '--name', 
            "Use the profile's NAME instead of its UUID as the file's basename.") do
      options[:profile_filename] = :name
    end

    options[:dl_dir] = "."
    opts.on('-d', '--download-dir DIR', 
            "Save the ADMC content to DIR (will be created if non-existent).") do |dir|
      if not dir.nil?
        options[:dl_dir] = dir
      end
      if not File.exists?(options[:dl_dir])
        Dir.mkdir(options[:dl_dir])
      end
    end

    options[:secretKey] = ""
    opts.on('-s', '--secret-key SECRETKEY', 
            'The secret_key for the config file if required.') do |secret_key|
      if not secret_key.nil?
        options[:secretKey] = secret_key
      end
    end

    options[:dump] = false
    opts.on('-j', '--json [FILE]', 
            'Dump the ADMC content in JSON format to FILE. Default is standard out.') do
      options[:dump] = true
    end

    options[:logfile] = nil
    opts.on('-l', '--logfile [LOGFILE]', 
            "Log HTTP actions to LOGFILE. Default is '#{File.basename($0)}.log'.") do |logfile|
      options[:logfile] = logfile.nil? ? "#{File.basename($0)}.log" : logfile
    end
    
    opts.separator "General options:"
    opts.on( '-h', '--help', 'Display this text.' ) do
      puts opts
      exit
    end    
  }
  
  if (args.empty?)
    puts opts
    exit
  end
  
  begin 
    opts.parse!(args)
  rescue
    puts opts
    exit 1
  end

  parse_config(options) unless options[:config_file].nil?

  options
end

def main()
  begin
    options = parse_command_line(ARGV)
  rescue OptionParser::ParseError => e
    puts "Invalid argument: #{e}"
    puts "Try -h for help."
    exit 1
  end
  
  info("Downloading ADMC certificates and profiles for Apple ID '#{options[:login]}' to directory '#{options[:dl_dir]}'.")
  @ADC = AppleDeveloperCenter.new(options)
  site = @ADC.fetch_site_data()

  if (options[:verbose])
    text = site.to_json
    if (options[:output])
      File.open(options[:output], 'w') {|f| f.write(text)}
    else
      puts text
    end
  end
end

main()
