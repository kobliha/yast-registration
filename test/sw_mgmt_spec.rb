#! /usr/bin/env rspec

require_relative "spec_helper"
require_relative "yast_stubs"

require "suse/connect"

describe "Registration::SwMgmt" do
  let(:yast_pkg) { double("Yast::Pkg") }

  let(:service_name) { "SLES" }
  let(:repos) do
    {
      # installation repository, not from registration
      0 => {
        "alias"=>"SLES12", "autorefresh"=>false,
        "base_urls"=>["cd:///"],
        "enabled"=>true, "is_update_repo"=>false, "keeppackages"=>false,
        "mirror_list"=>"", "name"=>"SLES12", "priority"=>99, "product_dir"=>"",
        "service"=>"", "type"=>"SUSE",
        "url"=>"cd:///"
      },
      # pool repo from service
      1 => {
        "alias"=>"SLES:SLES12-Pool", "autorefresh"=>true,
        "base_urls"=>["https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12-POOL"],
        "enabled"=>true, "is_update_repo"=>false, "keeppackages"=>false,
        "mirror_list"=>"", "name"=>"SLES12-Pool", "priority"=>99, "product_dir"=>"",
        "service"=>service_name, "type"=>"YUM",
        "url"=>"https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12-POOL"
      },
      # update repo from service
      2 => {
        "alias"=>"SLES:SLES12-Updates", "autorefresh"=>true,
        "base_urls"=>["https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12"],
        "enabled"=>true, "is_update_repo"=>true, "keeppackages"=>false,
        "mirror_list"=>"", "name"=>"SLES12-Updates", "priority"=>99, "product_dir"=> "",
        "service"=>service_name, "type"=>"YUM",
        "url"=>"https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12"
      },
      # update repo from a different service
      3 => {
        "alias"=>"Another:SLES12-Updates", "autorefresh"=>true,
        "base_urls"=>["https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12"],
        "enabled"=>true, "is_update_repo"=>true, "keeppackages"=>false,
        "mirror_list"=>"", "name"=>"SLES12-Updates", "priority"=>99, "product_dir"=> "",
        "service"=> "Another", "type"=>"YUM",
        "url"=>"https://nu.novell.com/suse/x86_64/update/SLE-SERVER/12"
      }
    }
  end

  before do
    stub_yast_require
    require "registration/sw_mgmt"

    stub_const("Yast::Pkg", yast_pkg)
  end

  describe ".service_repos" do
    let(:service) { double }

    before do
      expect(service).to receive(:name).and_return(service_name)

      expect(yast_pkg).to receive(:SourceGetCurrent).with(false).and_return(repos.keys)
      repos.each do |id, repo|
        expect(yast_pkg).to receive(:SourceGeneralData).with(id).and_return(repo)
      end
    end

    it "returns list of repositories belonging to a service" do
      expect(Registration::SwMgmt.service_repos(service)).to eq([repos[1], repos[2]])
    end

    it "optionally returns only update repositories" do
      expect(Registration::SwMgmt.service_repos(service, only_updates: true)).to eq([repos[2]])
    end
  end

  describe ".base_product_to_register" do
    it "returns base product base version and release_type" do
      expect(Registration::SwMgmt).to(receive(:find_base_product)
        .and_return({"name" => "SLES", "arch" => "x86_64", "version" => "12.1-1.47", "flavor" => "DVD"}))

      expect(Registration::SwMgmt.base_product_to_register).to eq({"name" => "SLES",
          "arch" => "x86_64", "version" => "12.1", "release_type" => "DVD"})
    end
  end

  describe ".add_services" do
    let(:service_url) { "https://example.com/foo/bar?credentials=TEST_credentials" }
    let(:credentials) { SUSE::Connect::Credentials.new("user", "password", "file") }
    let(:product_service) do
      SUSE::Connect::Remote::Service.new(
        "name" => service_name,
        "url" => service_url,
        "product" => {}
      )
    end
    let(:yast_mode) { double("Yast::Mode") }

    before do
      expect(yast_pkg).to receive(:SourceSaveAll).and_return(true).twice
      expect(yast_pkg).to receive(:ServiceRefresh).with(service_name).and_return(true)
      expect(yast_pkg).to receive(:ServiceSave).with(service_name).and_return(true)
      expect_any_instance_of(SUSE::Connect::Credentials).to receive(:write)

      allow(yast_pkg).to receive(:SourceGetCurrent).with(false).and_return(repos.keys)
      repos.each do |id, repo|
        allow(yast_pkg).to receive(:SourceGeneralData).with(id).and_return(repo)
      end

      stub_const("Yast::Mode", yast_mode)
      expect(yast_mode).to receive(:update).and_return(false)
    end

    it "it creates a new service if the service does not exist yet" do
      expect(yast_pkg).to receive(:ServiceAliases).and_return([])
      expect(yast_pkg).to receive(:ServiceAdd).with(service_name, service_url).and_return(true)
      expect(yast_pkg).to receive(:ServiceSet).with(service_name, hash_including("autorefresh" => true)).and_return(true)
      expect { Registration::SwMgmt.add_service(product_service, credentials) }.to_not raise_error
    end

    it "updates the existing service if the service already exists" do
      expect(yast_pkg).to receive(:ServiceAliases).and_return([service_name])
      expect(yast_pkg).to receive(:ServiceSet).with(
        service_name, hash_including("url" => service_url)).and_return(true)
      expect { Registration::SwMgmt.add_service(product_service, credentials) }.to_not raise_error
    end
  end

  describe ".copy_old_credentials" do
    let(:root_dir) { "/mnt" }
    let(:target_dir) {SUSE::Connect::Credentials::DEFAULT_CREDENTIALS_DIR}

    before do
      expect(Registration::SwMgmt).to receive(:zypp_config_writable!)

      expect(File).to receive(:exist?).with(target_dir).and_return(false)
      expect(FileUtils).to receive(:mkdir_p).with(target_dir)
    end

    it "does not fail when the old credentials are missing" do
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "NCCcredentials")).and_return(false)
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "SCCcredentials")).and_return(false)

      # no copy
      expect(FileUtils).to receive(:cp).never

      expect { Registration::SwMgmt.copy_old_credentials(root_dir) }.to_not raise_error
    end

    it "copies old NCC credentials at upgrade" do
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "NCCcredentials")).and_return(true)
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "SCCcredentials")).and_return(false)

      expect(FileUtils).to receive(:cp).with(File.join(root_dir, target_dir, "NCCcredentials"),
        File.join(target_dir, "SCCcredentials"))
      expect(SUSE::Connect::Credentials).to receive(:read)

      expect { Registration::SwMgmt.copy_old_credentials(root_dir) }.to_not raise_error
    end

    it "copies old SCC credentials at upgrade" do
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "NCCcredentials")).and_return(false)
      expect(File).to receive(:exist?).with(File.join(root_dir, target_dir, "SCCcredentials")).and_return(true)

      expect(FileUtils).to receive(:cp).with(File.join(root_dir, target_dir, "SCCcredentials"),
        File.join(target_dir, "SCCcredentials"))
      expect(SUSE::Connect::Credentials).to receive(:read)

      expect { Registration::SwMgmt.copy_old_credentials(root_dir) }.to_not raise_error
    end
  end

  describe ".find_addon_updates" do
    it "returns new available addons for installed addons" do
      # installed: SLES11-SP2 + SLE11-SP2-SDK + SLE11-SP2-Webyast
      expect(yast_pkg).to receive(:ResolvableProperties).with("", :product, "") \
        .and_return(YAML.load_file(fixtures_file("products_sp2_update.yml")))
      # available: SDK, HA, HA-GEO, ...
      available_addons = YAML.load_file(fixtures_file("available_addons.yml"))

      addon_updates = Registration::SwMgmt.find_addon_updates(available_addons)
      # an update only for SDK addon is available
      expect(addon_updates).to have(1).items
      expect(addon_updates.first.label).to \
        eq("SUSE Linux Enterprise Software Development Kit 12 x86_64")
    end
  end

end
