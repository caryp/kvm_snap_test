#!/usr/bin/env ruby

require "logger"
require "set"
require "right_http_connection"
require "right_cloud_stack"

API_RETRY_DELAY_SEC = 5
 
# Monkey patch String class for right_cloud_stack purposes
#
class String
  def right_blank?
    self.empty?
  end
end

# Helper class for dealing with CDC volumes
#
class CDCAPI
  
  # CloudStack diskOffering and KVM zone
  #
  # CDC 2.2.11
  DISK_OFFERING = "13" # 1GB
  ZONE = 1
  # DP
  # DISK_OFFERING = "47" # 10GB
  # ZONE = 1
  
  def initialize(endpoint_url, api_key, secret_key, logger = nil)
    @log = logger
    @log ||= Logger.new(STDOUT)
        
    version = "2.2"
    
    @device = { 
      "1" => "/dev/vdb",
      "2" => "/dev/vdc", 
      "3" => "/dev/vdd",
      "4" => "/dev/vde", 
      "5" => "/dev/vdf", 
      "6" => "/dev/vdg", 
      "7" => "/dev/vdh", 
      "8" => "/dev/vdi", 
      "9" => "/dev/vdj",
    }
    
    @cloud_stack = RightScale::CloudStackFactory.right_cloud_stack_class_for_version(version).new(api_key, secret_key, endpoint_url)
  end
  
  # Direct access to right_cloud_stack gem
  # Useful for debugging in irb
  def handle
    @cloud_stack
  end

  # === Returns
  # String:: newly created volume id
  def volume_create(name)
    @log.info "Creating volume #{name} from offering id #{DISK_OFFERING}..."
    ret = @cloud_stack.create_volume(name, ZONE, DISK_OFFERING)
    id = ret["createvolumeresponse"]["jobid"]
    wait_for_job id
    vol_id = ret["createvolumeresponse"]["id"]
    @log.info "Created volume id: #{vol_id}"
    vol_id
  end

  # === Returns
  # String:: newly created volume id
  def volume_create_from_snap(name, snapshot_id)
    retries = 3
    begin 
      @log.info "Creating volume #{name} from snapshot id #{snapshot_id}..."
      ret = @cloud_stack.create_volume(name, ZONE, nil, snapshot_id)
      id = ret["createvolumeresponse"]["jobid"]
      wait_for_job id
    rescue Exception => e
      retries -= 1
      if retries > 0
        @log.error "Failed. #{e.message}. Retrying..."
        retry
      end
      raise e
    end
    vol_id = ret["createvolumeresponse"]["id"]
    @log.info "Created volume id: #{vol_id}"
    vol_id
  end
  
  # Waits for attachment
  def volume_attach(vm_id, volume_id)
    @log.info "Attaching volume #{volume_id} to VM #{vm_id}..."
    ret = @cloud_stack.attach_volume(volume_id, vm_id)
    id = ret["attachvolumeresponse"]["jobid"] 
    wait_for_job id 
    @log.info "Attached."
    result = job_result(id)
    device_id = result["queryasyncjobresultresponse"]["jobresult"]["volume"]["deviceid"]
    @device[device_id]
  end
  
  def volume_detach(volume_id)
    @log.info "Detaching volume #{volume_id}..."
    ret = @cloud_stack.detach_volume(volume_id)
    id = ret["detachvolumeresponse"]["jobid"] 
    wait_for_job id 
    @log.info "Detached."
    result = job_result(id)
    result
  end
  
  def volume_delete(volume_id)
    @log.info "Deleting volume #{volume_id}..."
    ret = @cloud_stack.delete_volume(volume_id)
    success = ret["deletevolumeresponse"]["success"] 
    @log.info "Deleted. #{success}" 
  end
  
  def snapshot_create(volume_id)
    @log.info "Creating snapshot from #{volume_id}..."
    ret = @cloud_stack.create_snapshot(volume_id)
    id = ret["createsnapshotresponse"]["jobid"] 
    wait_for_job id, 30
    @log.info "done."
    result = job_result(id)
    snap_id = result["queryasyncjobresultresponse"]["jobresult"]["snapshot"]["id"]
    snap_id
  end
  
  def snapshot_delete(snap_id)
    @log.info "Deleting volume #{snap_id}..."
    ret = @cloud_stack.delete_snapshot(snap_id)
    id = ret["deletesnapshotresponse"]["jobid"] 
    wait_for_job id 
    @log.info "Deleted."
  end
  
  # Use this to deduce the attached device -- since KVM does not 
  # attach to the device we request
  def get_current_devices(proc_partitions_output)
    lines = proc_partitions_output.split("\n")
    partitions = lines.drop(2).map do |line|
      line.chomp.split.last
    end.reject do |partition|
      partition =~ /^dm-\d/
    end
    devices = partitions.select do |partition|
      partition =~ /[a-z]$/
    end.sort.map {|device| "/dev/#{device}"}
    if devices.empty?
      devices = partitions.select do |partition|
        partition =~ /[0-9]$/
      end.sort.map {|device| "/dev/#{device}"}
    end
    devices
  end

  private
  
  def job_result(jobid)
    result = @cloud_stack.query_async_job_result(jobid)
    @log.debug "Result: #{result.inspect}"
    result
  end
  
  def job_running?(jobid)
    ret = job_result(jobid)
    unless ret["queryasyncjobresultresponse"]["jobresultcode"] == "0" 
      error_code = ret["queryasyncjobresultresponse"]["jobresult"]["errorcode"]
      error_msg = ret["queryasyncjobresultresponse"]["jobresult"]["errortext"]
      raise "ERROR: job failed. Code:#{error_code} Message: #{error_msg}" 
    end
    ret["queryasyncjobresultresponse"]["jobstatus"] == "0" # 0 = PENDING
  end
  
  def wait_for_job(jobid, delay_sec = 5)
    while job_running?(jobid)
      @log.info "Waiting..."
      sleep delay_sec
    end
  end
 
end


