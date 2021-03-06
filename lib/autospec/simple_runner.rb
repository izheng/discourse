require "autospec/rspec_runner"

module Autospec

  class SimpleRunner < RspecRunner
    def initialize
      @mutex = Mutex.new
    end

    def run(specs)
      puts "Running Rspec: " << specs
      # kill previous rspec instance
      @mutex.synchronize do
        self.abort
      end
      # we use our custom rspec formatter
      args = ["-r", "#{File.dirname(__FILE__)}/formatter.rb"]

      command = begin
        if ENV["PARALLEL_SPEC"] &&
              !specs.split.any? { |s| puts s; s =~ /\:/ } # Parallel spec can't run specific groups

          args += ["-f", "progress", "-f", "Autospec::ParallelFormatter", "-o", "./tmp/rspec_result"]
          args += ["-f", "ParallelTests::RSpec::RuntimeLogger", "-o", "./tmp/parallel_runtime_rspec.log"] if specs == "spec"

          "parallel_rspec -- #{args.join(" ")} -- #{specs.split.join(" ")}"
        else
          args += ["-f", "Autospec::Formatter"]
          "bin/rspec #{args.join(" ")} #{specs.split.join(" ")}"
        end
      end

      # launch rspec
      Dir.chdir(Rails.root) do
        env = { "RAILS_ENV" => "test" }
        if specs.split(' ').any? { |s| s =~ /^(.\/)?plugins/ }
          env["LOAD_PLUGINS"] = "1"
          puts "Loading plugins while running specs"
        end
        pid =
          @mutex.synchronize do
            @pid = Process.spawn(env, command)
          end

        _, status = Process.wait2(pid)

        status.exitstatus
      end
    end

    def abort
      if pid = @pid
        Process.kill("TERM", pid) rescue nil
        wait_for_done(pid)
        pid = nil
      end
    end

    def stop
      # assume sigint on child will take care of this?
      if pid = @pid
        wait_for_done(pid)
      end
    end

    def wait_for_done(pid)
      i = 3000
      while (i > 0 && Process.getpgid(pid) rescue nil)
        sleep 0.001
        i -= 1
      end
      if (Process.getpgid(pid) rescue nil)
        STDERR.puts "Terminating rspec #{pid} by force cause it refused graceful termination"
        Process.kill("KILL", pid)
      end
    end

  end

end
