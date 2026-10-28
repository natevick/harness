  around do |example|
    previous_fifo = ENV["SELECTIVE_TRANSPORT_FIFO"]
    ENV["SELECTIVE_TRANSPORT_FIFO"] = "1"
    example.run
  ensure
    if previous_fifo.nil?
      ENV.delete("SELECTIVE_TRANSPORT_FIFO")
    else
      ENV["SELECTIVE_TRANSPORT_FIFO"] = previous_fifo
    end
  end
