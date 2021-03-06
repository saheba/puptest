# To change this license header, choose License Headers in Project Properties.
# To change this template file, choose Tools | Templates
# and open the template in the editor.

require 'set'
require 'socket'
require 'vmpool/callback_server'
require 'util/command_module'

## requires at least libvirt-bin/virsh 0.10.2
class PoolManager
  include CommandModule
  
  attr_reader :opts, :pool, :currently_in_use
  
  PUPTEST_INIT_STATE = 'puptest_init_state'
  
  def initialize(opts = {})
    opts = ensure_all_options_are_initialized(opts)
    @opts = opts
    
    @currently_in_use = Set.new   
  end
  
  def ensure_all_options_are_initialized(opts={})
    opts[:callback_server_ip] = '192.168.122.1' if opts[:callback_server_ip] == nil
    opts[:callback_server_port] = 2828 if opts[:callback_server_port] == nil
    opts[:vm_network_for_ssh] = 'default' if opts[:vm_network_for_ssh] == nil
    opts[:vm_host_interface] = 'virbr0' if opts[:vm_host_interface] == nil
    opts[:vm_host_mac_ip_map_file] = '/var/log/daemon.log' if opts[:vm_host_mac_ip_map_file] == nil
    opts[:vm_host_url] = 'localhost' if opts[:vm_host_url] == nil
    opts[:vm_name_prefix] = 'puptest_' if opts[:vm_name_prefix] == nil
    opts[:base_vm] = 'puptest_base' if opts[:base_vm] == nil
    opts[:pool_size] = 3 if opts[:pool_size] == nil
    opts[:vm_engine] = 'kvm' if opts[:vm_engine] == nil
    opts[:vm_host_login] = 'root' if opts[:vm_host_login] == nil
    opts[:vm_level] = 'system' if opts[:vm_level] == nil
    opts[:vol_pool_path] = '/tmp' if opts[:vol_pool_path] == nil
    opts[:vol_file_suffix] = '.qcow2' if opts[:vol_file_suffix] == nil
    opts[:init_snapshot_name] = PUPTEST_INIT_STATE if opts[:init_snapshot_name] == nil
    opts[:pool_vm_login] = 'root' if opts[:pool_vm_login] == nil
    opts[:pool_vm_identity_file] = '/tmp/puptest-base_rsa' if opts[:pool_vm_identity_file] == nil
    opts[:vm_pool_network] = '192.168.122' if opts[:vm_pool_network] == nil
    # note that key-based ssh authentication is required for security reasons  
    return opts
  end
  
  def delete_pool(opts=self.opts)
    all_pool_vms = get_all_pool_vms(opts)
    all_pool_vms.each do |pool_vm|
      delete_vm(opts,pool_vm)
    end
    
    @pool = nil
    return all_pool_vms
  end
  
  def stop_pool(opts=self.opts)    
    result = stop_vms(opts,get_running_pool_vms(opts))
    @pool = Set.new
    return result
  end
  
  def restart_pool(opts=self.opts)
    start_pool(opts)
  end
  
  def occupy(pool=self.pool,in_use = self.currently_in_use)
    ## select vm
    selected_vm = pool.to_a[0]
    ## remove vm from pool of usable vms
    pool.delete(selected_vm)
    in_use.add(selected_vm)
    
    return selected_vm
  end
  
  def free(vm, pool=self.pool, opts=self.opts, in_use = self.currently_in_use)
    virsh_connection = get_virsh_connection_string(opts)
    in_use.delete(vm)
    info = run_command(virsh_connection+' snapshot-dumpxml '+vm+' '+opts[:init_snapshot_name])
    if info[1] == 0
      pool, vm = revert_vm(pool,vm,opts)
      ## revert_vm does not necessarily add vm back to pool
      pool.add(vm)
      ensure_vms_are_running(opts,[vm])
    else
      # TODO delete vm pysically
      delete_vm(opts,vm)
      pool.delete(vm)
      pool, vm = add_vm_to_pool(pool,opts)
      ensure_vms_are_running(opts,[vm])
    end
    return pool, vm
  end
  
  def start_pool(opts=self.opts)
    @vm_ip_map = Hash.new
    virsh_connection = get_virsh_connection_string(opts)
    
    ensure_base_vm_exists(opts)
    stop_vms(opts,get_running_pool_vms(opts))
        
    all_pool_vms = get_all_pool_vms(opts)
    all_pool_vms_duplicate = all_pool_vms.clone()
    
    ## check if there is a puptest init snapshot, 
    ## if so reset each pool vm to this init snapshot state otherwise delete the vm
    ## TODO refactor using blocks
    all_pool_vms_duplicate.each do |pool_vm|
      all_pool_vms, vm = free(pool_vm, all_pool_vms, opts=self.opts)
    end
    
    ## adjust pool to defined pool size
    break_condition = all_pool_vms.size - opts[:pool_size]
    puts Thread.current.to_s+" :: break_condition :"+break_condition.to_s
    if break_condition != 0
      pool_change_type = break_condition > 0 ? :reduce : :extend
      break_condition = -break_condition if break_condition < 0
      if (pool_change_type == :reduce)
        count = 0
        all_pool_vms_duplicate = all_pool_vms.clone()
        all_pool_vms_duplicate.each do |pool_vm|        
          # TODO delete vm pysically
          delete_vm(opts,pool_vm)
          all_pool_vms.delete(pool_vm)        
          count += 1;
          break if (count >= break_condition)
        end
      elsif (pool_change_type == :extend)
        (1..break_condition).each do
          all_pool_vms, pool_vm = add_vm_to_pool(all_pool_vms,opts)
        end
      end
    end
    
    ## ensure all pool vms are running    
    ensure_vms_are_running(opts, all_pool_vms)
    
    @pool = all_pool_vms
    
    return all_pool_vms
  end
  
  def revert_vm(pool,vm,opts)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    revert = run_command(virsh_connection+' snapshot-revert '+vm+' '+opts[:init_snapshot_name])
    if revert[1] != 0
      # TODO delete vm physically
      delete_vm(opts,vm)
      pool.delete(vm)
      pool, vm = add_vm_to_pool(pool,opts)
    end
    return pool, vm
  end
  
  def add_vm_to_pool(pool,opts)
    vm_name = clone_base_vm(opts)
    ## create snapshot in VM
    create_vm_snapshot(opts,vm_name)
    pool.add(vm_name)
    return pool, vm_name
  end
  
  def get_virsh_connection_string(opts)
    opts = ensure_all_options_are_initialized(opts)
    return 'virsh -c qemu+ssh://'+opts[:vm_host_login]+'@'+
      opts[:vm_host_url]+'/'+opts[:vm_level]
  end
  
  def get_ssh_connection_string(opts)
    opts = ensure_all_options_are_initialized(opts)
    return 'ssh -o StrictHostKeyChecking=no -o HashKnownHosts=no '+opts[:vm_host_login]+'@'+
      opts[:vm_host_url]
  end
  
  def get_all_pool_vms(opts,only_running=false)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    
    selector=' --all'
    if (only_running)
      selector=''
    end
    pool_list_all = run_command(virsh_connection+' list'+selector+' --name | grep '+opts[:vm_name_prefix])
    all_vms = array_to_set(pool_list_all[0].split(/\n/))
    all_vms.delete(opts[:base_vm])
    all_pool_vms = regexp_based_subset(all_vms,/^#{opts[:vm_name_prefix]}/)
    return all_pool_vms
  end
  
  def get_running_pool_vms(opts)
    return get_all_pool_vms(opts,true)
  end
  
#  def get_ip_mac_map_of_host_interface(opts)
#    ssh_connection = get_ssh_connection_string(opts)
#    entry_list = run_command(ssh_connection+' grep '+opts[:vm_host_interface]+' '+opts[:vm_host_mac_ip_map_file])
#    plain_entries = entry_list[0].split(/\n/)
#    
#    mac_ip_map = Hash.new
#    plain_entries.each do |entry_line|
#      ip_entry = regexp_match_ip(entry_line)
#      mac_entry = regexp_match_mac(entry_line)
#      if ip_entry && mac_entry
#        ## last occurrence wins (i.e. overwrites previous occurrences)
#        mac_ip_map[mac_entry[0]] = ip_entry[0]        
#      end
#    end
#    
#    return mac_ip_map
#  end
  
  def get_vm_ssh_connection_string(vm,opts=self.opts)
    ip = get_ssh_connection_ip_of_vm(vm,opts)
    if ip == nil
        raise(ConnectionOrExecuteException,Thread.current.to_s+' ::ip for vm '+vm+' could not be determined.')
    end
    abs_identity_file=opts[:pool_vm_identity_file]
    if !File.exists?(abs_identity_file)
      rel_identity_file = File.join(File.dirname(__FILE__),opts[:pool_vm_identity_file])
      if !File.exists?(rel_identity_file)
        raise(ConnectionOrExecuteException,'pool_vm_identity_file could not be found in: '+abs_identity_file+' or in: '+rel_identity_file)
      end
      abs_identity_file = rel_identity_file
    end
    return 'ssh -o StrictHostKeyChecking=no -o HashKnownHosts=no -i '+abs_identity_file+' '+opts[:pool_vm_login]+'@'+ip
  end
  
  def get_ssh_connection_ip_of_vm(vm,opts=self.opts)
    return @vm_ip_map[vm]
#    mac_ip_map = get_ip_mac_map_of_host_interface(opts)
#    mac_ip_map.each do |mac,ip|
##      puts Thread.current.to_s+" :: found mac -> ip relation: "+mac.to_s+' -> '+ip.to_s
#    end
#    ## determine mac address of vm
#    virsh_connection = get_virsh_connection_string(opts)    
#    domiflist,statuscode = run_command(virsh_connection+' domiflist '+vm)
#    if statuscode != 0
#      raise(ConnectionOrExecuteException,'virsh domiflist failed for vm: '+vm)
#    end
#    iflist_lines = domiflist.split(/\n/)
#        
#    iflist_lines.each do |line|
#      regexp = Regexp.new(/#{opts[:vm_network_for_ssh]}/)
#      network_match = regexp.match(line)            
#      if network_match
#        mac_address = regexp_match_mac(line)
#        if (mac_address)
#          ip = 'nil'
#          if mac_ip_map[mac_address[0]]
#            ip = mac_ip_map[mac_address[0]]
#          end
#          puts Thread.current.to_s+" :: found mac address "+mac_address[0]+" for vm "+vm+' -> '+ip
#        end
#         if (mac_address && mac_ip_map[mac_address[0]])
#          return mac_ip_map[mac_address[0]]
#        end
#      end
#    end
#    
#    return nil
  end
  
  ## scripts is an array of Script objects
  
  def run_command_in_pool_vm(command, vm, opts=self.opts)
    opts = ensure_all_options_are_initialized(opts)
    if pool == nil
      raise(ConnectionOrExecuteException,'Pool is not (yet) initiated. Run pool_start before you run a command in a pool vm')
    end
    ## run command in selected vm
    vm_ssh_connection = get_vm_ssh_connection_string(vm,opts)
    output, statuscode = run_command(vm_ssh_connection+' '+command)
    
    ## return output array [output, statuscode]
    return output, statuscode
  end
  
  private
  
  def regexp_match_ip(line)
    return Regexp.new(/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/).match(line)
  end
  
  def regexp_match_mac(line)
    return Regexp.new(/([0-9a-f]{2}[:-]){5}[0-9a-f]{2}/).match(line)
  end
  
  def ensure_base_vm_exists(opts)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    # check if base vm exists
    base_vm_exists = run_command(virsh_connection+' dominfo '+opts[:base_vm])
    
    if base_vm_exists[1] != 0
      raise(PoolStartException,'Base VM '+opts[:base_vm]+' does not exist on host '+
          opts[:vm_host_url]+'/'+opts[:vm_level]+'. Please check your configuration.\n'+base_vm_exists[0].to_s)
    end
  end
  
  def delete_all_snapshots(opts,vm_name)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    list_snapshots = run_command(virsh_connection+' snapshot-list '+vm_name)
    if list_snapshots[1] != 0
      raise(ConnectionOrExecuteException,'Snapshots could not be listed for vm: '+vm_name)
    end
    snapshot_lines = array_to_set(list_snapshots[0].split(/\n/))
    snapshot_lines.each do |line|   
      trimmed_line = line.strip      
      match = Regexp.new(/^#{opts[:vm_name_prefix]}\S*/).match(trimmed_line)      
      if match        
        del_snapshot = run_command(virsh_connection+' snapshot-delete --children '+vm_name+' '+match[0])
        if del_snapshot[1] != 0
          raise(ConnectionOrExecuteException,'vm snapshot could not be deleted.')
        end
      end
    end
        
    
    
    return list_snapshots[0]
  end
  
  def create_vm_snapshot(opts,vm_name)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    create_snapshot = run_command(virsh_connection+' snapshot-create-as '+vm_name+' '+opts[:init_snapshot_name])
    if create_snapshot[1] != 0
      raise(ConnectionOrExecuteException,'vm snapshot could not be created.')
    end
    
    return create_snapshot[0]
  end
  
  def list_vm_names(opts,state=:running)
    virsh_connection = get_virsh_connection_string(opts)
    case state 
    when :running
      state_param = '--state-running'
    when :paused
      state_param = '--state-paused'
#    when :shutoff
#      state_param = '--state-shutoff'
    when :all
      state_param = '--all'
    else
      state_param = ''
    end
    
    vms = nil
    if state != :shutoff
      vms_list = run_command(virsh_connection+' list --name '+state_param)    
      if vms_list[1] != 0
        raise(ConnectionOrExecuteException,'vm list could not be executed properly. (state = '+state.to_s+')')
      end
      vms = array_to_set(vms_list[0].split(/\n/))
    else
      ## --state-shutoff bug workaround (--state-shutoff does not filter correctly)
      all_vms = list_vm_names(opts,:all)
      running_vms = list_vm_names(opts,:running)
      paused_vms = list_vm_names(opts,:paused)
      not_stopped = running_vms + paused_vms
      vms = all_vms - not_stopped      
    end
    
    return vms
  end
  
  def ensure_vms_are_running(opts,vms)
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    
    running_vms = list_vm_names(opts)
    paused_vms = list_vm_names(opts,:paused)
    
    mutex = Mutex.new
    mutex.synchronize do
      vms.each do |vm|
        if (!running_vms.include?(vm))
          ## try to start i.e. resume vm
          start_vm = nil
          if (paused_vms.include?(vm))
            start_vm = run_command(virsh_connection+' resume '+vm)
          else
            start_vm = run_command(virsh_connection+' start '+vm)
            puts Thread.current.to_s+" :: trying to start callback server "+opts[:callback_server_ip]+':'+opts[:callback_server_port].to_s
            thread = CallbackServer.new.wait_for_callback(opts) { |msg| 
              puts "received msg from completely started server: "+msg 
              vm_ip = add_ip_to_vm_ip_map(vm,msg,@vm_ip_map,opts)
              if (vm_ip == nil)
                raise(ConnectionOrExecuteException,'did not found ip of vm in callback message or could not parse the callback message properly.')
              end
            }
            puts Thread.current.to_s+" :: before join"
            thread.join
            puts Thread.current.to_s+" :: after join"
          end
          if start_vm[1] != 0
            raise(PoolStartException,'VM '+vm+' could not be started or resumed.')
          end
          counter = 0
          while get_ssh_connection_ip_of_vm(vm,opts) == nil && counter < 10
            puts "waiting for vm "+vm+" to appear in "+opts[:vm_host_mac_ip_map_file]+" ... "+counter.to_s
            sleep(1)
            counter += 1
          end
        end
      end
    end 
    
    return vms
  end
  
  def add_ip_to_vm_ip_map(vm,msg,map,opts)
    ips = msg.split(',')
    ips.each do |ip|
      ipt = ip.strip
      match = Regexp.new(/^#{opts[:vm_pool_network]}/).match(ipt)      
      ends_with_1 = Regexp.new(/\.1$/).match(ipt)
      ends_with_255 = Regexp.new(/\.255$/).match(ipt)
      if (match && !ends_with_1 && !ends_with_255)
          map[vm] = ipt
      end
    end
       
    return map[vm]
  end
  
  def delete_vm(opts,vm_name)
    puts Thread.current.to_s+' :: deleting vm '+vm_name
    ## remove all snapshots of vm
    delete_all_snapshots(opts,vm_name)
    
    virsh_connection = get_virsh_connection_string(opts)    
    ## ensure vm is stopped    
    stopped_vms = list_vm_names(opts,:shutoff)
    stopped_status = 0
    if (!stopped_vms.include?(vm_name))
      output, stopped_status = deactivate_vm(opts,vm_name,'destroy')      
    end
    ## then delete vm
    result = [output,stopped_status]
    puts Thread.current.to_s+' :: deleting vm '+vm_name+' stopped status '+stopped_status.to_s
    if (stopped_status == 0)
      result = deactivate_vm(opts,vm_name,'undefine --remove-all-storage')
    end
    return result
  end
  
  def stop_vms(opts,vms)
    vms.each do |vm|
      # shutdown command only works after full boot, so we use destroy 
      # to be sure it was shutdown
      deactivate_vm(opts,vm,'destroy')
    end
    
    return vms
  end
  
  def deactivate_vm(opts,vm_name,cmd='shutdown')
    opts = ensure_all_options_are_initialized(opts)
    virsh_connection = get_virsh_connection_string(opts)
    
    delete = run_command(virsh_connection+' '+cmd+' '+vm_name)
    if delete[1] != 0
      raise(DeleteException,'VM '+vm_name+' command failed: '+cmd+"\n"+delete[0])
    end
    puts delete[0]
    
    return delete
  end
  
  def clone_base_vm(opts)    
    opts = ensure_all_options_are_initialized(opts)
    virtclone_connection='virt-clone --connect qemu+ssh://'+opts[:vm_host_login]+'@'+
      opts[:vm_host_url]+'/'+opts[:vm_level]+' --original '+opts[:base_vm]
    identifier = Time.now.strftime('%s_%12N')
    vm_name = opts[:vm_name_prefix] + identifier
    clone = run_command(virtclone_connection+
        ' --name '+vm_name+
        ' --file '+opts[:vol_pool_path]+File::SEPARATOR+vm_name+opts[:vol_file_suffix])
    if clone[1] != 0
      raise(CloneException,"Clone "+vm_name+" of base VM "+opts[:base_vm]+" could not be created.")
    end
    puts "base vm clone created: "+vm_name
    
    return vm_name
  end
  
  def regexp_based_subset(set, regexp)
    subset = Set.new()
    set.each do |item|
      if item =~ regexp
        subset.add(item)
      end
    end
    
    return subset
  end
  
  def array_to_set(array)
    set = Set.new()
    array.each do |item|
      set.add(item)
    end
    
    return set
  end
  
end

class PoolStartException < StandardError
  
end

class CloneException < StandardError
  
end

class DeleteException < StandardError
  
end

class ConnectionOrExecuteException < StandardError
  
end