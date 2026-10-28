around { |example| with_env("SELECTIVE_TRANSPORT_FIFO" => "1") { example.run } }
