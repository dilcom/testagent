module TestAgent
  ##
  # Class contains OpenNebula virtual machine
  # and offers interface for bootstrapping chef node
  # and for using Sikulix screen actions
  class TestNode
    include OpenNebula
    include TestAgentConfig
    include TestAgentLogger

    attr_reader :name
    attr_accessor :vnc_screen

    ##
    # Add methods from SikuliScreen class (click, type etc)
    $SIKULI_SCREEN.java_class.java_instance_methods.map(&:name).uniq.each do |name|
      define_method(name) do |*args, &block|
        unless @vnc_screen
          warn('No vnc screen initialized')
          return
        end
        @vnc_screen.method(name).call(*args, &block)
      end
    end

    ##
    # Get client used to connect to OpenNebula host.
    # @return [OpenNebula::Client] client.
    def client
      @client ||= Client.new(config[:credentials], config[:end_point])
    end

    ##
    # Get virtual machine from OpenNebula by it`s id.
    # @param vm_id[Int] id of virtual machine.
    # @return [VirtualMachine] OpenNebula virtual machine.
    def locate_vm(vm_id)
      vm_pool = VirtualMachinePool.new(client, -1)
      rc = vm_pool.info
      if OpenNebula.is_error?(rc)
        error rc.message
        return
      end
      vm = vm_pool.find { |el| el.id == vm_id }
      unless "#{vm.class}" == 'OpenNebula::VirtualMachine'
        error "VM Not found #{vm.class}"
        return
      end
      vm
    end


    ##
    # Detect node`s ip address.
    # @return [String, nil] ip address or nil if it couldn't be found.
    # TODO: improve that method (setup a dhcp server and make it's table accessible outside)
    def detect_ip
      mac = vm_info['VM']['TEMPLATE']['NIC']['MAC']
      20.times do
        debug 'Trying to get IP...'
        out = `echo '#{config[:local_sudo_pass]}' | sudo -S nmap -sP -n 153.15.248.0/21`
        out = out.lines
        index = out.find_index { |s| s =~ /.*#{mac}.*/i }
        if index
          return out.to_a[index - 2].scan(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)[0]
        end
      end
      warn "Can't locate VM ip"
      nil
    end

    ##
    # Get node`s ip address.
    # @return [String, nil] ip address or nil if it couldn't be found.
    def ip
      unless @vm
        warn 'No Vm assigned to locate IP'
        return
      end
      @ip ||= detect_ip
    end

    ##
    # Remove virtual machine in OpenNebula.
    # @return [true, false] true if machine deleted successfully, false otherwise.
    def delete_vm
      unless @vm
        info 'No VM assigned, nothing to delete'
        return false
      end
      system("knife node delete #{chef_name} -y")
      # TODO: make changes here after switching to newer version of OpenNebula
      locate_vm(id).finalize
      @vm = nil
      @ip = nil
      true
    end

    ##
    # Create new #TestNode and OpenNebula virtual machine.
    # @param vm_name [String] part of machine`s name in OpenNebula (second part is timestamp).
    # @param template_name [String] template used to instantiate new virtual machine.
    # @return [String] name.
    def initialize(vm_name, template_name, keep_vm_alive = false)
      @name = vm_name
      temp_pool = TemplatePool.new(client, -1)
      rc = temp_pool.info
      if OpenNebula.is_error?(rc)
        error rc.message
        return nil
      end
      template = temp_pool.find { |el| el.name == template_name }
      unless "#{template.class}" == 'OpenNebula::Template'
        error "Template Not found #{template.class}"
        return nil
      end
      vir_mac = false
      until vir_mac
        vm_id = template.instantiate("#{vm_name}(#{Time.now.utc.iso8601})")
        if OpenNebula.is_error?(vm_id)
          error "Some problem in instantiating template\n#{vm_id.message}"
          delete_vm
          next
        end
        unless "#{vm_id.class}" == 'Fixnum'
          error 'Some problem in instantiating template'
          return nil
        end
        vir_mac = locate_vm(vm_id) # locate vm inside pool by id, wait for start
        delete_vm unless vir_mac
      end
      unless "#{vir_mac.class}" == 'OpenNebula::VirtualMachine'
        error 'Some problem in Getting Virtual Machine'
        return nil
      end
      @vm = vir_mac
    end

    ##
    # Get info about opennebula virtual michine associated with that node.
    # @return [Hash] info.
    def vm_info
      unless @vm
        warn 'No VM assigned to get info from'
        return
      end
      @vm = locate_vm(@vm.to_hash['VM']['ID'].to_i)
      @vm.to_hash
    end

    ##
    # Get id of OpenNebula VM associated with that #TestNode.
    # @return [String] id.
    def id
      vm_info['VM']['ID'].to_i
    end

    ##
    # Get name of chef node associated with that #TestNode.
    # @return [String] name.
    def chef_name
      "#{name}_#{id}"
    end

    ##
    # Check if port open.
    # @param ip [String] target ip address.
    # @param port [String] target port.
    # @return [true, false] true if port is open false otherwise.
    def port_open?(ip, port)
      begin
        Timeout.timeout(10) do
          begin
            s = TCPSocket.new(ip, port)
            s.close
            return true
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
            return false
          end
        end
      rescue Timeout::Error
        return false
      end
    end

    ##
    # Formats bootstrap command from options
    def bootstrap_command(options)
      options[:ssh_password] ||= config[:default_ssh_pass]
      cmd = "knife bootstrap #{ip} -P #{options[:ssh_password]} -N #{chef_name}"
      cmd += " --config '#{options[:config]}'" if options[:config]
      cmd += " -r '#{options[:run_list]}'" if options[:run_list]
      cmd += " -j '#{options[:data]}'" if options[:data]
      cmd
    end

    ##
    # Bootstraps chef client on TestNode
    # @param [Hash] options chef options.
    # @option options [String] :run_list Runlist passed to chef
    # @option options [String] :data Some data passed to chef
    # @option options [String] :ssh_password Ssh password on target machine
    # @option options [String] :config Path to knife config file
    # @return [true, false] true if node bootstrapped successfully, false otherwise
    def bootstrap(options = {})
      unless @vm
        warn 'No VM assigned to bootstrap chef-client'
        return false
      end
      debug 'Bootstrapping...'
      i = 30
      while i && !port_open?(ip, '22')
        i -= 1
        sleep(15)
      end
      result = system("#{bootstrap_command(options)}")
      error 'Some error during bootstrapping' unless result
      result
    end

    ##
    # Check whether VM is ok. Method wait for machine to be running and then checks it state.
    # @return [Boolean] true if machine is running, false if failed.
    def vm_ok?
      unless @vm
        warn 'No VM initialized'
        return false
      end
      inf = vm_info
      # wait while vm is waiting for instantiating
      while [0, 1, 2].include? inf['VM']['LCM_STATE'].to_i
        sleep 10
        inf = vm_info
      end
      inf['VM']['STATE'].to_i == 3 # state 3 - VM is running
    end

    private :port_open?, :client, :locate_vm, :detect_ip,
            :bootstrap_command

    # TODO: add some method to allow changing Chef runlist during testing
  end
end
