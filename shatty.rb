require "clamp"
require "pty"
require "ftw"

class Shatty < Clamp::Command
  subcommand "record", "Record a command" do
    option ["-o", "--output"], "PATH_OR_URL",
      "where to output the recording to (a path or url)",
      :default => "output.shatty"
    option "--headless", :flag,
      "headless mode; don't output anything to stdout."
    parameter "COMMAND ...", "The command to run",
      :attribute_name => :command

    def execute
      start = Time.now
      if output =~ /^https?:/
        agent = FTW::Agent.new
        stream, out = IO::pipe
        Thread.new { 
          response = agent.post!(output, :body => stream)
          # TODO(sissel): Shouldn't get here...
        }
      else
        out = File.new(output, "w")
      end

      # binary mode.
      buffer = ""

      STDOUT.sync = true
      terminal, keyboard, pid = PTY.spawn(*command)
      system("stty raw -echo") # yeah, perhaps we should use termios instead.

      # Dump stdin to the tty's keyboard
      # We could use reopen here, but the 'keyboard' io has mode read/write.
      Thread.new { STDIN.each_char { |c| keyboard.syswrite(c) } }

      while true
        # Read from the terminal output and compute the time offset
        begin
          terminal.sysread(16834, buffer)
        rescue Errno::EIO => e
          Process.waitpid(pid)
          puts "Command exited with code: #{$?.exitstatus}"
          break
        end

        time_offset = Time.now - start

        # for each chunk of text read from tmux, record
        # the timestamp (duration since 'start' of recording)
        out.syswrite([time_offset.to_f, buffer.length, buffer].pack("GNA#{buffer.length}"))

        $stdout.write(buffer) unless headless?
      end

      system("stty sane")
    end # def execute
  end # subcommand "record"

  subcommand "play", "Play a recording" do
    parameter "[PATH_OR_URL]",
      "The recording to play. This can be a path or URL.",
      :attribute_name => :path

    def execute
      # TODO(sissel): Don't abort :(
      Thread.abort_on_exception = true 

      if path =~ /^https?:/
        input, writer = IO::pipe
        Thread.new do 
          agent = FTW::Agent.new
          response = agent.get!(path)
          response.read_http_body { |chunk| writer.syswrite(chunk) }
        end
      else
        input = File.new(path, "w")
      end

      start = nil

      $stdout.sync = true
      headersize = [1,1].pack("GN").size
      last_time = 0
      while true
        # Read the header
        begin
          buffer = input.read(headersize)
          time, length = buffer.unpack("GN")
          buffer = input.read(length)
        rescue EOFError
          break
        end

        # Sleep if necessary
        #sleep(time - last_time) if last_time > 0
        last_time = time

        # output this frame.
        $stdout.syswrite(buffer)
      end
    end # def execute
  end # subcommand "play"
end # class Shatty

Shatty.run
