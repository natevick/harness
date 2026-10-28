def write(message)
  @stdin.write("#{message}\n")
rescue Errno::EPIPE, IOError
  raise ConnectionLostError
end
