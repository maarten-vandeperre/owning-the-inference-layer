import java.net.URI;
import java.net.http.*;
import java.time.Duration;

/** Container health probe, using the installed JRE instead of requiring curl. */
public class Healthcheck {
    public static void main(String[] args) {
        try (var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build()) {
            var request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + System.getenv().getOrDefault("QUARKUS_HTTP_PORT", "8080") + "/q/health/ready"))
                .timeout(Duration.ofSeconds(3)).GET().build();
            if (client.send(request, HttpResponse.BodyHandlers.discarding()).statusCode() != 200)
                System.exit(1);
        } catch (Exception e) { System.exit(1); }
    }
}
