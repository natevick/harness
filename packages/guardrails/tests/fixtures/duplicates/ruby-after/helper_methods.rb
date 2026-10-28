def with_env(values)
  previous = values.keys.to_h { |key| [key, ENV[key]] }
  ENV.update(values)
  yield
ensure
  ENV.update(previous)
end
