class EmptyCatch {
    void close(java.io.Closeable stream) {
        try {
            stream.close();
        } catch (Exception ignored) {
        }
    }
}
