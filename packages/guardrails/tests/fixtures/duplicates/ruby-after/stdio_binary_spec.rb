with_env("SELECTIVE_TRANSPORT" => binary, "SELECTIVE_TRANSPORT_FIFO" => nil) do
  Timeout.timeout(8) { controller.start }
end
