public class ForkedSurefireIT {
    void run(ProcessBuilder builder, int port) {
        ClientRun.conformanceEnvironment(builder, port);
    }
}
