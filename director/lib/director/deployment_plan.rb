# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::Director
  class DeploymentPlan
  end
end

require "director/deployment_plan/compilation_config"
require "director/deployment_plan/idle_vm"
require "director/deployment_plan/instance"
require "director/deployment_plan/job"
require "director/deployment_plan/network"
require "director/deployment_plan/network_subnet"
require "director/deployment_plan/package"
require "director/deployment_plan/release"
require "director/deployment_plan/resource_pool"
require "director/deployment_plan/stemcell"
require "director/deployment_plan/template"
require "director/deployment_plan/update_config"

require "director/deployment_plan/dynamic_network"
require "director/deployment_plan/manual_network"
require "director/deployment_plan/vip_network"

module Bosh::Director
  # TODO: cleanup exceptions
  # DeploymentPlan encapsulates essential director data structures retrieved
  # from the deployment manifest and the running environment.
  class DeploymentPlan
    include DnsHelper
    include ValidationHelper

    attr_accessor :name
    attr_accessor :canonical_name
    attr_accessor :deployment
    attr_accessor :properties
    attr_accessor :compilation
    attr_accessor :update
    attr_accessor :unneeded_instances
    attr_accessor :unneeded_vms
    attr_accessor :dns_domain

    attr_reader :jobs
    attr_reader :job_rename
    attr_reader :recreate

    # TODO: decouple initialization from manifest parsing to make testing easier
    def initialize(manifest, options = {})
      @manifest = manifest
      @recreate = !!options["recreate"]
      @job_states = safe_property(options, "job_states",
                                  :class => Hash, :default => {})

      @deployment = nil
      @job_rename = safe_property(options, "job_rename",
                                  :class => Hash, :default => {})
      @unneeded_vms = []
      @unneeded_instances = []
      @dns_domain = nil

      parse_name
      parse_properties
      parse_releases
      parse_networks
      parse_compilation
      parse_update
      parse_resource_pools
      parse_jobs
    end

    # Returns a named job
    # @param [String] name Job name
    # @return [Bosh::Director::DeploymentPlan::JobSpec] Job
    def job(name)
      @jobs_name_index[name]
    end

    # Returns all networks in a deployment plan
    # @return [Array<Bosh::Director::DeploymentPlan::NetworkSpec>]
    def networks
      @networks.values
    end

    # Returns a named network
    # @param [String] name
    # @return [Bosh::Director::DeploymentPlan::NetworkSpec]
    def network(name)
      @networks[name]
    end

    # Returns all resource pools in a deployment plan
    # @return [Array<Bosh::Director::DeploymentPlan::ResourcePoolSpec>]
    def resource_pools
      @resource_pools.values
    end

    # Returns a named resource pool spec
    # @param [String] name Resource pool name
    # @return [Bosh::Director::DeploymentPlan::ResourcePoolSpec]
    def resource_pool(name)
      @resource_pools[name]
    end

    # Returns all releases in a deployment plan
    # @return [Array<Bosh::Director::DeploymentPlan::ReleaseSpec>]
    def releases
      @releases.values
    end

    # Returns a named release
    # @return [Bosh::Director::DeploymentPlan::ReleaseSpec]
    def release(name)
      @releases[name]
    end

    # Adds a VM to deletion queue
    # TODO: rename to "mark_vm_for_deletion"
    # @param [Bosh::Director::Models::Vm] vm VM DB model
    #
    def delete_vm(vm)
      @unneeded_vms << vm
    end

    # Adds instance to deletion queue
    # TODO: rename to  "mark_instance_for_deletion"
    # @param [Bosh::Director::Models::Instance] instance Instance DB model
    def delete_instance(instance)
      if @jobs_name_index.has_key?(instance.job)
        @jobs_name_index[instance.job].unneeded_instances << instance
      else
        @unneeded_instances << instance
      end
    end

    def rename_in_progress?
      @job_rename["old_name"] && @job_rename["new_name"]
    end

    private

    def parse_name
      @name = safe_property(@manifest, "name", :class => String)
      @canonical_name = canonical(@name)
    end

    def parse_properties
      @properties = safe_property(@manifest, "properties",
                                  :class => Hash, :default => {})
      @properties.extend(DeepCopy)
    end

    def parse_releases
      release_specs = []

      if @manifest.has_key?("release")
        if @manifest.has_key?("releases")
          raise "Deployment manifest contains both 'release' and 'releases' " +
                  "sections, please use one of the two."
        end
        release_specs << @manifest["release"]
      else
        safe_property(@manifest, "releases", :class => Array).each do |release|
          release_specs << release
        end
      end

      @releases = {}
      release_specs.each do |release_spec|
        release = ReleaseSpec.new(self, release_spec)
        if @releases.has_key?(release.name)
          raise "Duplicate release name: '#{release.name}'."
        end
        @releases[release.name] = release
      end
    end

    def parse_resource_pools
      @resource_pools = {}
      resource_pools = safe_property(@manifest, "resource_pools",
                                     :class => Array)
      resource_pools.each do |resource_pool_spec|
        resource_pool = ResourcePoolSpec.new(self, resource_pool_spec)
        if @resource_pools[resource_pool.name]
          raise "Duplicate resource pool name: '#{resource_pool.name}'."
        end
        @resource_pools[resource_pool.name] = resource_pool
      end

      # Uncomment when integration test fixed
      # raise "No resource pools specified." if @resource_pools.empty?
    end

    def parse_jobs
      @jobs = []
      @jobs_name_index = {}
      @jobs_canonical_name_index = Set.new

      jobs = safe_property(@manifest, "jobs", :class => Array, :default => [])

      jobs.each do |job|
        state_overrides = @job_states[job["name"]]

        if state_overrides
          job.recursive_merge!(state_overrides)
        end

        if rename_in_progress? && @job_rename["old_name"] == job["name"]
          raise "Renamed job #{job["name"]} is being referenced in " +
                "deployment manifest"
        end

        job = JobSpec.new(self, job)
        if @jobs_canonical_name_index.include?(job.canonical_name)
          raise "Invalid job name: '#{job.name}', canonical name already taken."
        end

        @jobs << job
        @jobs_name_index[job.name] = job
        @jobs_canonical_name_index << job.canonical_name
      end
    end

    def parse_networks
      @networks = {}
      @networks_canonical_name_index = Set.new
      networks = safe_property(@manifest, "networks", :class => Array)
      networks.each do |network_spec|
        type = safe_property(network_spec, "type", :class => String,
                             :default => "manual")
        case type
          when "manual"
            network = ManualNetworkSpec.new(self, network_spec)
          when "dynamic"
            network = DynamicNetworkSpec.new(self, network_spec)
          when "vip"
            network = VipNetworkSpec.new(self, network_spec)
          else
            raise "Invalid network type: '#{type}'."
        end

        if @networks_canonical_name_index.include?(network.canonical_name)
          raise "Invalid network name: '%s', canonical name already taken." % (
            network.name)
        end
        @networks[network.name] = network
        @networks_canonical_name_index << network.canonical_name
      end

      raise "No networks specified." if @networks.empty?
    end

    def parse_update
      @update = UpdateConfig.new(
          safe_property(@manifest, "update", :class => Hash))
    end

    def parse_compilation
      @compilation = CompilationConfig.new(self, safe_property(
          @manifest, "compilation", :class => Hash))
    end
  end
end
