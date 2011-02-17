require 'puppet/application'

class Puppet::Application::Kick < Puppet::Application

  should_not_parse_config

  attr_accessor :hosts, :tags, :classes

  option("--all","-a")
  option("--foreground","-f")
  option("--debug","-d")
  option("--ping","-P")
  option("--test")

  option("--host HOST") do |arg|
    @hosts << arg
  end

  option("--tag TAG", "-t") do |arg|
    @tags << arg
  end

  option("--class CLASS", "-c") do |arg|
    @classes << arg
  end

  option("--no-fqdn", "-n") do |arg|
    options[:fqdn] = false
  end

  option("--parallel PARALLEL", "-p") do |arg|
    begin
      options[:parallel] = Integer(arg)
    rescue
      $stderr.puts "Could not convert #{arg.inspect} to an integer"
      exit(23)
    end
  end

  def help
    <<-HELP

puppet-kick(8) -- Remotely control puppet agent
========

SYNOPSIS
--------
Trigger a puppet agent run on a set of hosts.


USAGE
-----
puppet kick [-a|--all] [-c|--class <class>] [-d|--debug] [-f|--foreground]
  [-h|--help] [--host <host>] [--no-fqdn] [--ignoreschedules]
  [-t|--tag <tag>] [--test] [-p|--ping] <host> [<host> [...]]


DESCRIPTION
-----------
This script can be used to connect to a set of machines running 'puppet
agent' and trigger them to run their configurations. The most common
usage would be to specify a class of hosts and a set of tags, and
'puppet kick' would look up in LDAP all of the hosts matching that
class, then connect to each host and trigger a run of all of the objects
with the specified tags.

If you are not storing your host configurations in LDAP, you can specify
hosts manually.

You will most likely have to run 'puppet kick' as root to get access to
the SSL certificates.

'puppet kick' reads 'puppet master''s configuration file, so that it can
copy things like LDAP settings.


USAGE NOTES
-----------
'puppet kick' is useless unless 'puppet agent' is listening. See its
documentation for more information, but the gist is that you must enable
'listen' on the 'puppet agent' daemon, either using '--listen' on the
command line or adding 'listen = true' in its config file. In addition,
you need to set the daemons up to specifically allow connections by
creating the 'namespaceauth' file, normally at
'/etc/puppet/namespaceauth.conf'. This file specifies who has access to
each namespace; if you create the file you must add every namespace you
want any Puppet daemon to allow -- it is currently global to all Puppet
daemons.

An example file looks like this:

    [fileserver]
        allow *.madstop.com

    [puppetmaster]
        allow *.madstop.com

    [puppetrunner]
        allow culain.madstop.com

This is what you would install on your Puppet master; non-master hosts
could leave off the 'fileserver' and 'puppetmaster' namespaces.


OPTIONS
-------
Note that any configuration parameter that's valid in the configuration
file is also a valid long argument. For example, 'ssldir' is a valid
configuration parameter, so you can specify '--ssldir <directory>' as an
argument.

See the configuration file documentation at
http://docs.puppetlabs.com/references/latest/configuration.html for
the full list of acceptable parameters. A commented list of all
configuration options can also be generated by running puppet master
with '--genconfig'.

* --all:
  Connect to all available hosts. Requires LDAP support at this point.

* --class:
  Specify a class of machines to which to connect. This only works if
  you have LDAP configured, at the moment.

* --debug:
  Enable full debugging.

* --foreground:
  Run each configuration in the foreground; that is, when connecting to
  a host, do not return until the host has finished its run. The default
  is false.

* --help:
  Print this help message

* --host:
  A specific host to which to connect. This flag can be specified more
  than once.

* --ignoreschedules:
  Whether the client should ignore schedules when running its
  configuration. This can be used to force the client to perform work it
  would not normally perform so soon. The default is false.

* --parallel:
  How parallel to make the connections. Parallelization is provided by
  forking for each client to which to connect. The default is 1, meaning
  serial execution.

* --tag:
  Specify a tag for selecting the objects to apply. Does not work with
  the --test option.

* --test:
  Print the hosts you would connect to but do not actually connect. This
  option requires LDAP support at this point.

* --ping:
  Do a ICMP echo against the target host. Skip hosts that don't respond
  to ping.


EXAMPLE
-------
    $ sudo puppet kick -p 10 -t remotefile -t webserver host1 host2


AUTHOR
------
Luke Kanies


COPYRIGHT
---------
Copyright (c) 2005 Puppet Labs, LLC Licensed under the GNU Public
License

    HELP
  end

  def run_command
    @hosts += command_line.args
    options[:test] ? test : main
  end

  def test
    puts "Skipping execution in test mode"
    exit(0)
  end

  def main
    require 'puppet/network/client'

    Puppet.warning "Failed to load ruby LDAP library. LDAP functionality will not be available" unless Puppet.features.ldap?
    require 'puppet/util/ldap/connection'

    todo = @hosts.dup

    failures = []

    # Now do the actual work
    go = true
    while go
      # If we don't have enough children in process and we still have hosts left to
      # do, then do the next host.
      if @children.length < options[:parallel] and ! todo.empty?
        host = todo.shift
        pid = fork do
          run_for_host(host)
        end
        @children[pid] = host
      else
        # Else, see if we can reap a process.
        begin
          pid = Process.wait

          if host = @children[pid]
            # Remove our host from the list of children, so the parallelization
            # continues working.
            @children.delete(pid)
            failures << host if $CHILD_STATUS.exitstatus != 0
            print "#{host} finished with exit code #{$CHILD_STATUS.exitstatus}\n"
          else
            $stderr.puts "Could not find host for PID #{pid} with status #{$CHILD_STATUS.exitstatus}"
          end
        rescue Errno::ECHILD
          # There are no children left, so just exit unless there are still
          # children left to do.
          next unless todo.empty?

          if failures.empty?
            puts "Finished"
            exit(0)
          else
            puts "Failed: #{failures.join(", ")}"
            exit(3)
          end
        end
      end
    end
  end

  def run_for_host(host)
    if options[:ping]
      out = %x{ping -c 1 #{host}}
      unless $CHILD_STATUS == 0
        $stderr.print "Could not contact #{host}\n"
        next
      end
    end

    require 'puppet/run'
    Puppet::Run.indirection.terminus_class = :rest
    port = Puppet[:puppetport]
    url = ["https://#{host}:#{port}", "production", "run", host].join('/')

    print "Triggering #{host}\n"
    begin
      run_options = {
        :tags => @tags,
        :background => ! options[:foreground],
        :ignoreschedules => options[:ignoreschedules]
      }
      run = Puppet::Run.indirection.save(Puppet::Run.new( run_options ), url)
      puts "Getting status"
      result = run.status
      puts "status is #{result}"
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      $stderr.puts "Host #{host} failed: #{detail}\n"
      exit(2)
    end

    case result
    when "success";
      exit(0)
    when "running"
      $stderr.puts "Host #{host} is already running"
      exit(3)
    else
      $stderr.puts "Host #{host} returned unknown answer '#{result}'"
      exit(12)
    end
  end

  def initialize(*args)
    super
    @hosts = []
    @classes = []
    @tags = []
  end

  def preinit
    [:INT, :TERM].each do |signal|
      trap(signal) do
        $stderr.puts "Cancelling"
        exit(1)
      end
    end
    options[:parallel] = 1
    options[:verbose] = true
    options[:fqdn] = true
    options[:ignoreschedules] = false
    options[:foreground] = false
  end

  def setup
    if options[:debug]
      Puppet::Util::Log.level = :debug
    else
      Puppet::Util::Log.level = :info
    end

    # Now parse the config
    Puppet.parse_config

    if Puppet[:node_terminus] == "ldap" and (options[:all] or @classes)
      if options[:all]
        @hosts = Puppet::Node.indirection.search("whatever", :fqdn => options[:fqdn]).collect { |node| node.name }
        puts "all: #{@hosts.join(", ")}"
      else
        @hosts = []
        @classes.each do |klass|
          list = Puppet::Node.indirection.search("whatever", :fqdn => options[:fqdn], :class => klass).collect { |node| node.name }
          puts "#{klass}: #{list.join(", ")}"

          @hosts += list
        end
      end
    elsif ! @classes.empty?
      $stderr.puts "You must be using LDAP to specify host classes"
      exit(24)
    end

    @children = {}

    # If we get a signal, then kill all of our children and get out.
    [:INT, :TERM].each do |signal|
      trap(signal) do
        Puppet.notice "Caught #{signal}; shutting down"
        @children.each do |pid, host|
          Process.kill("INT", pid)
        end

        waitall

        exit(1)
      end
    end

  end

end
