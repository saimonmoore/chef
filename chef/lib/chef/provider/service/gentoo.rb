#
# Author:: Lee Jensen (<ljensen@engineyard.com>)
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

require 'chef/provider/service'
require 'chef/mixin/command'

class Chef
  class Provider
    class Service
      class Gentoo < Chef::Provider::Service::Init
        def load_current_resource
          super
          
          raise Chef::Exception::Service unless ::File.exists?("/sbin/rc-update")
          
          status = popen4("/sbin/rc-update -s default") do |pid, stdin, stdout, stderr|
            stdout.each_line do |line|
              if line.match(/^\s*#{@current_resource.service_name}\s+/)
                @current_resource.enabled true
              end
            end
          end
          
          unless status.exitstatus == 0
            raise Chef::Exception::Service, "/sbin/rc-update -s default failed - #{status.inspect}"
          end
          
          @current_resource
        end
        
        def enable_service()
          run_command(:command => "/sbin/rc-update add #{@new_resource.service_name} default")
        end
        
        def disable_service()
          run_command(:command => "/sbin/rc-update del #{@new_resource.service_name} default")
        end
      end
    end
  end
end
