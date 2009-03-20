#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
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

require 'chef/config'
require 'chef/mixin/params_validate'
require 'chef/mixin/generate_url'
require 'chef/mixin/checksum'
require 'chef/log'
require 'chef/rest'
require 'chef/platform'
require 'chef/node'
require 'chef/file_cache'
require 'chef/compile'
require 'chef/runner'
require 'ohai'

class Chef
  class Client
    
    include Chef::Mixin::GenerateURL
    include Chef::Mixin::Checksum
    
    attr_accessor :node, :registration, :safe_name, :json_attribs, :validation_token, :node_name
    
    # Creates a new Chef::Client.
    def initialize()
      @node = nil
      @safe_name = nil
      @validation_token = nil
      @registration = nil
      @json_attribs = nil
      @node_name = nil
      @rest = Chef::REST.new(Chef::Config[:registration_url])
    end
    
    # Do a full run for this Chef::Client.  Calls:
    # 
    #  * build_node - Get the last known state, merge with local changes
    #  * register - Make sure we have an openid
    #  * authenticate - Authenticate with our openid
    #  * sync_definitions - Populate the local cache with all the definitions
    #  * sync_recipes - Populate the local cache with all the recipes
    #  * do_attribute_files - Populate the local cache with all attributes, and execute them
    #  * save_node - Store the new node configuration
    #  * converge - Bring this system up to date, based on the local cache
    #  * save_node - Store the node again, in case convergence altered future state
    #
    # === Returns
    # true:: Always returns true.
    def run
      start_time = Time.now
      Chef::Log.info("Starting Chef Run")
      
      build_node(@node_name)
      register
      authenticate
      sync_library_files
      sync_attribute_files
      sync_definitions
      sync_recipes
      save_node
      converge
      save_node
      
      end_time = Time.now
      Chef::Log.info("Chef Run complete in #{end_time - start_time} seconds")
      true
    end
    
    # Similar to Chef::Client#run, but instead of talking to the Chef server,
    # simply runs in a standalone ("solo") mode.
    #
    # Someday, we'll have chef_chewbacca.
    #
    # === Returns
    # true:: Always returns true.
    def run_solo
      start_time = Time.now
      Chef::Log.info("Starting Chef Solo Run")
      
      build_node(@node_name, solo = true)
      converge()
      
      end_time = Time.now
      Chef::Log.info("Chef Run complete in #{end_time - start_time} seconds")
      true
    end
    
    # Builds a new node object for this client.  Starts with querying for the FQDN of the current
    # host (unless it is supplied), then merges in the facts from Ohai.
    #
    # === Parameters
    # node_name<String>:: The name of the node to build - defaults to nil
    #
    # === Returns
    # node<Chef::Node>:: Returns the created node object, also stored in @node
    def build_node(node_name=nil, solo=false)
      Ohai::Log.logger = Chef::Log.logger
      ohai = Ohai::System.new
      ohai.all_plugins
      
      node_name ||= ohai[:fqdn] ? ohai[:fqdn] : ohai[:hostname]      
      raise RuntimeError, "Unable to determine node name from ohai" unless node_name
      @safe_name = node_name.gsub(/\./, '_')
      Chef::Log.debug("Building node object for #{@safe_name}")
      unless solo
        begin
          @node = @rest.get_rest("nodes/#{@safe_name}")
        rescue Net::HTTPServerException => e
          unless e.message =~ /^404/
            raise e
          end
        end
      end
      unless @node
        @node ||= Chef::Node.new
        @node.name(node_name)
      end
      if @json_attribs
        Chef::Log.debug("Adding JSON Attributes")
        @json_attribs.each do |key, value|
          if key == "recipes"
            value.each do |recipe|
              unless @node.recipes.detect { |r| r == recipe }
                Chef::Log.debug("Adding recipe #{recipe}")
                @node.recipes << recipe
              end
            end
          else
            Chef::Log.debug("JSON Attribute: #{key} - #{value.inspect}")
            @node[key] = value
          end
        end
      end
      ohai.each do |field, value|
        Chef::Log.debug("Ohai Attribute: #{field} - #{value.inspect}")
        @node[field] = value
      end
      platform, version = Chef::Platform.find_platform_and_version(@node)
      Chef::Log.debug("Platform is #{platform} version #{version}")
      @node[:platform] = platform
      @node[:platform_version] = version
      @node[:tags] = Array.new unless @node.attribute?(:tags)
      @node
    end
    
    # If this node has been registered before, this method will fetch the current registration
    # data.
    #
    # If it has not, we register it by calling create_registration.
    #
    # === Returns
    # true:: Always returns true
    def register
      Chef::Log.debug("Registering #{@safe_name} for an openid") 
      @registration = nil
      begin
        @registration = @rest.get_rest("registrations/#{@safe_name}")
      rescue Net::HTTPServerException => e
        unless e.message =~ /^404/
          raise e
        end
      end
      
      if @registration
        @secret = Chef::FileCache.load(File.join("registration", @safe_name))
      else
        create_registration
      end
      true
    end
    
    # Generates a random secret, stores it in the Chef::Filestore with the "registration" key,
    # and posts our nodes registration information to the server.
    #
    # === Returns
    # true:: Always returns true
    def create_registration
      @secret = random_password(500)
      Chef::FileCache.store(File.join("registration", @safe_name), @secret)
      @rest.post_rest("registrations", { :id => @safe_name, :password => @secret, :validation_token => @validation_token })
      true
    end
    
    # Authenticates the node via OpenID.
    #
    # === Returns
    # true:: Always returns true
    def authenticate
      Chef::Log.debug("Authenticating #{@safe_name} via openid") 
      response = @rest.post_rest('openid/consumer/start', { 
        "openid_identifier" => "#{Chef::Config[:openid_url]}/openid/server/node/#{@safe_name}",
        "submit" => "Verify"
      })
      Chef::Log.debug("After authenticating #{@safe_name} via openid got response: #{response.inspect}") 
      @rest.post_rest(
        "#{Chef::Config[:openid_url]}#{response["action"]}",
        { "password" => @secret }
      )
    end
    
    # Update the file caches for a given cache segment.  Takes a segment name
    # and a hash that matches one of the cookbooks/_attribute_files style
    # remote file listings.
    #
    # === Parameters
    # segment<String>:: The cache segment to update
    # remote_list<Hash>:: A cookbooks/_attribute_files style remote file listing
    def update_file_cache(segment, remote_list)  
      # We need the list of known good attribute files, so we can delete any that are
      # just laying about.
      file_canonical = Hash.new
      
      remote_list.each do |rf|
        cache_file = File.join("cookbooks", rf['cookbook'], segment, rf['name'])
        file_canonical[cache_file] = true
      
        current_checksum = nil
        if Chef::FileCache.has_key?(cache_file)
          current_checksum = checksum(Chef::FileCache.load(cache_file, false))
        end
      
        rf_url = generate_cookbook_url(
          rf['name'], 
          rf['cookbook'], 
          segment, 
          @node, 
          current_checksum ? { 'checksum' => current_checksum } : nil
        )
        Chef::Log.debug(rf_url)
      
        changed = true
        begin
          raw_file = @rest.get_rest(rf_url, true)
        rescue Net::HTTPRetriableError => e
          if e.response.kind_of?(Net::HTTPNotModified)
            changed = false
            Chef::Log.debug("Cache file #{cache_file} is unchanged")
          else
            raise e
          end
        end
      
        if changed
          Chef::Log.info("Storing updated #{cache_file} in the cache.")
          Chef::FileCache.move_to(raw_file.path, cache_file)
        end
      end
      
      Chef::FileCache.list.each do |cache_file|
        if cache_file.match("cookbooks/.+?/#{segment}")
          unless file_canonical[cache_file]
            Chef::Log.info("Removing #{cache_file} from the cache; it is no longer on the server.")
            Chef::FileCache.delete(cache_file)
          end
        end
      end
      
    end
    
    # Gets all the attribute files included in all the cookbooks available on the server,
    # and executes them.
    #
    # === Returns
    # true:: Always returns true
    def sync_attribute_files
      Chef::Log.debug("Synchronizing attributes")
      update_file_cache("attributes", @rest.get_rest('cookbooks/_attribute_files'))
      true
    end
    
    # Gets all the library files included in all the cookbooks available on the server,
    # and loads them.
    #
    # === Returns
    # true:: Always returns true
    def sync_library_files
      Chef::Log.debug("Synchronizing libraries")
      update_file_cache("libraries", @rest.get_rest('cookbooks/_library_files'))
      true
    end
    
    # Gets all the definition files included in all the cookbooks available on the server,
    # and loads them.
    #
    # === Returns
    # true:: Always returns true
    def sync_definitions
      Chef::Log.debug("Synchronizing definitions") 
      update_file_cache("definitions", @rest.get_rest('cookbooks/_definition_files'))
    end
    
    # Gets all the recipe files included in all the cookbooks available on the server,
    # and loads them.
    #
    # === Returns
    # true:: Always returns true
    def sync_recipes
      Chef::Log.debug("Synchronizing recipes") 
      update_file_cache("recipes", @rest.get_rest('cookbooks/_recipe_files'))
    end
    
    # Updates the current node configuration on the server.
    #
    # === Returns
    # true:: Always returns true
    def save_node
      Chef::Log.debug("Saving the current state of node #{@safe_name}")
      @node = @rest.put_rest("nodes/#{@safe_name}", @node)
      true
    end
    
    # Compiles the full list of recipes for the server, and passes it to an instance of
    # Chef::Runner.converge.
    #
    # === Returns
    # true:: Always returns true
    def converge
      Chef::Log.debug("Compiling recipes for node #{@safe_name}")
      Chef::Config[:cookbook_path] = File.join(Chef::Config[:file_cache_path], "cookbooks")
      compile = Chef::Compile.new()
      compile.node = @node
      compile.load_libraries
      compile.load_attributes
      compile.load_definitions
      compile.load_recipes

      Chef::Log.debug("Converging node #{@safe_name}")
      cr = Chef::Runner.new(@node, compile.collection)
      cr.converge
      true
    end
        
    protected
      # Generates a random password of "len" length.
      def random_password(len)
        chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
        newpass = ""
        1.upto(len) { |i| newpass << chars[rand(chars.size-1)] }
        newpass
      end

  end
end
