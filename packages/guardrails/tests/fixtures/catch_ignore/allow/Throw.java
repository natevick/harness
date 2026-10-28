class Throw {
    void write(String line) throws java.io.IOException {
        try {
            stream.write(line);
        } catch (java.io.IOException error) {
            throw new IllegalStateException(error);
        }
    }
}
