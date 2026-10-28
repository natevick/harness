  around do |example|
    keys = %w[SELECTIVE_TRANSPORT SELECTIVE_TRANSPORT_FIFO SELECTIVE_FAKE_MODE SELECTIVE_FAKE_DIR]
    previous = keys.to_h { |key| [key, ENV[key]] }
    ENV["SELECTIVE_TRANSPORT"] = fake_transport
    ENV["SELECTIVE_FAKE_DIR"] = directory
    ENV.delete("SELECTIVE_TRANSPORT_FIFO")
    example.run
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    FileUtils.rm_rf(directory) if directory
  end
