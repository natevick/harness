def close(device) do
  try do
    File.close(device)
  rescue
    error -> reraise(error, __STACKTRACE__)
  end
end
