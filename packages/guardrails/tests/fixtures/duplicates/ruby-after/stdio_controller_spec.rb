around { |example| with_env("SELECTIVE_TRANSPORT" => fake_transport, "SELECTIVE_FAKE_DIR" => directory) { example.run } }
