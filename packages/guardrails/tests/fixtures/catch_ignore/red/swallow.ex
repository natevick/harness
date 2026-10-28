def close(device) do
  try do
    File.close(device)
  rescue
    _ -> nil
  end
end
