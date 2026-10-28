def close
  @tcp.close
rescue IOError
  nil
end
