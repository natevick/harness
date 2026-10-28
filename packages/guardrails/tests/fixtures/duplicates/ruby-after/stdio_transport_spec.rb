around { |example| with_env("SELECTIVE_TRANSPORT" => fake_transport, "SELECTIVE_FAKE_DIR" => directory, "SELECTIVE_TRANSPORT_FIFO" => nil) { example.run } }
