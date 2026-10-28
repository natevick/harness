    previous_transport = ENV["SELECTIVE_TRANSPORT"]
    previous_fifo = ENV["SELECTIVE_TRANSPORT_FIFO"]
    ENV["SELECTIVE_TRANSPORT"] = binary
    ENV.delete("SELECTIVE_TRANSPORT_FIFO")

    Timeout.timeout(8) { controller.start }
    driver.join(2)

    received = []
    received << frames.pop(true) until frames.empty?
    ids = received.filter_map { |message| message.dig("data", "id") if message["type"] == "test_case_result" }

    expect(ran).to eq([["a", "b"], ["c"]])
    expect(ids).to eq(%w[a b c])
    expect(received.map { |message| message["type"] }).to include("report_at_finish")
    expect(statuses).to eq([0])
    expect(fifos - before_fifos).to eq([])
    expect(captured[:cmdline]).to eq([binary, "--stdio"]) if captured[:cmdline]
    expect(File.exist?("/tmp/stdio-runner_1")).to be(false)
    expect(File.exist?("/tmp/stdio-runner_2")).to be(false)
    pid = controller.transport_pid
    expect { Process.getpgid(pid) }.to raise_error(Errno::ESRCH)
  ensure
    ENV["SELECTIVE_TRANSPORT"] = previous_transport if defined?(previous_transport) && previous_transport
    ENV.delete("SELECTIVE_TRANSPORT") if defined?(previous_transport) && previous_transport.nil?
    if defined?(previous_fifo) && previous_fifo
      ENV["SELECTIVE_TRANSPORT_FIFO"] = previous_fifo
    elsif defined?(previous_fifo)
      ENV.delete("SELECTIVE_TRANSPORT_FIFO")
    end
