# -*- ruby -*-

require 'rubygems'
require 'hoe'
require './lib/ldap/version.rb'

require 'spec'
require 'spec/rake/spectask'
require 'pathname'

Hoe.new('dm-ldap-adapter', Ldap::VERSION) do |p|
  p.developer('mkristian', 'm.kristian@web.de')
  p.url = "http://dm-ldap-adapter.rubyforge.org"
  p.extra_deps = [['ruby-net-ldap', '=0.0.4'],'slf4r', ['dm-core', '<0.10.0']]
  p.remote_rdoc_dir = '' # Release to root
end

desc 'Install the package as a gem.'
task :install => [:clean, :package] do
  gem = Dir['pkg/*.gem'].first
  sh "gem install --local #{gem} --no-ri --no-rdoc"
end

desc 'Run specifications'
Spec::Rake::SpecTask.new(:spec) do |t|
  if File.exists?('spec/spec.opts')
    t.spec_opts << '--options' << 'spec/spec.opts'
  end
  t.spec_files = Pathname.glob('./spec/**/*_spec.rb')
end

require 'yard'

YARD::Rake::YardocTask.new

# vim: syntax=Ruby
