def write(line):
    try:
        stream.write(line + "\n")
        stream.flush()
    except OSError:
        raise ConnectionLost()
