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
#

require 'chef/cookbook_loader'

class Chef
  module Mixin
    module FindPreferredFile

      def load_cookbook_files(cookbook_id, file_type)
        unless file_type == :remote_file || file_type == :template
          raise ArgumentError, "You must supply :remote_file or :template as the file_type"
        end
        
        cl = Chef::CookbookLoader.new
        cookbook = cl[cookbook_id]
        raise NotFound unless cookbook

        files = Hash.new
        
        cookbook_method = nil
        
        case file_type
        when :remote_file
          cookbook_method = :remote_files
        when :template
          cookbook_method = :template_files
        end
                
        cookbook.send(cookbook_method).each do |rf|
          full = File.expand_path(rf)
          name = File.basename(full)
          case file_type
          when :remote_file
            rf =~ /^.+#{cookbook_id}[\\|\/]files[\\|\/](.+?)[\\|\/]#{name}/
          when :template
            rf =~ /^.+#{cookbook_id}[\\|\/]templates[\\|\/](.+?)[\\|\/]#{name}/
          end
          singlecopy = $1
          files[full] = {
            :name => name,
            :singlecopy => singlecopy,
            :file => full,
          }
        end
        Chef::Log.debug("Preferred #{file_type} list: #{files.inspect}")
        
        files
      end

      def find_preferred_file(cookbook_id, file_type, file_name, fqdn, platform, version)
        file_list = load_cookbook_files(cookbook_id, file_type)
        
        preferences = [
          File.join("host-#{fqdn}", "#{file_name}"),
          File.join("#{platform}-#{version}", "#{file_name}"),
          File.join("#{platform}", "#{file_name}"),
          File.join("default", "#{file_name}")
        ]
        to_send = nil
        
        preferences.each do |pref|
          Chef::Log.debug("Looking for #{pref}")
          file_list.each_key do |file|
            Chef::Log.debug("Checking for #{pref} #{file} ")
            if file =~ /#{pref}$/
              Chef::Log.debug("Matched #{pref} for #{file}!")
              to_send = file
              break
            end
          end
          break if to_send
        end
        
        unless to_send
          raise Chef::Exception::FileNotFound, "Cannot find a preferred file for #{file_name}!"
        end
        
        to_send
      end
      
    end
  end
end