public class ProtocolTest {
    public static Path repo() {
        Path cwd = Path.of("").toAbsolutePath();
        if ("core".equals(String.valueOf(cwd.getFileName()))) {
            return cwd.getParent();
        }
        return cwd;
    }

    public static void conformanceEnvironment(ProcessBuilder builder, int port) {
        String transport = System.getenv("SELECTIVE_TRANSPORT");
        if (transport == null || transport.isEmpty()) {
            transport = "/tmp/transport/target/release/transport";
        }
        builder.environment().put("SELECTIVE_TRANSPORT", transport);
        builder.environment().put("SELECTIVE_CONFORMANCE_FAST", "1");
        builder.environment().put("SELECTIVE_API_KEY", "conformance-key");
        builder.environment().put("SELECTIVE_PLATFORM", "github");
        builder.environment().put("SELECTIVE_RUN_ID", "run-1");
        builder.environment().put("SELECTIVE_RUN_ATTEMPT", "1");
        builder.environment().put("SELECTIVE_BRANCH", "main");
        builder.environment().put("SELECTIVE_SHA", "abc");
        builder.environment().put("SELECTIVE_GIT_REPO", "org/repo");
        builder.environment().put("SELECTIVE_GIT_PROVIDER", "github");
        builder.environment().put("SELECTIVE_RUNNER_ID", "runner-1");
        builder.environment().put("SELECTIVE_HOST", "ws://127.0.0.1:" + port);
    }

    public static String batch(String... ids) {
        StringBuilder body = new StringBuilder("{\"command\":\"run_test_cases\",\"test_case_ids\":[");
        for (int i = 0; i < ids.length; i++) {
            if (i > 0) {
                body.append(',');
            }
            body.append('"').append(ids[i].replace("\\", "\\\\").replace("\"", "\\\"")).append('"');
        }
        return body.append("]}").toString();
    }

    public static int count(String text, String token) {
        int found = 0;
        int index = 0;
        while ((index = text.indexOf(token, index)) >= 0) {
            found++;
            index += token.length();
        }
        return found;
    }
}
