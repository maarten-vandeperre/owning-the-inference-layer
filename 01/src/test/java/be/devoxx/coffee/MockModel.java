package be.devoxx.coffee;
import com.sun.net.httpserver.HttpServer;
import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
public class MockModel implements QuarkusTestResourceLifecycleManager {
    static final AtomicReference<String> content=new AtomicReference<>();
    static volatile String request,auth,path;
    static volatile int status=200;
    HttpServer server;
    public Map<String,String> start(){try{
        server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        server.createContext("/llm/demo/v1/chat/completions", exchange->{
            path=exchange.getRequestURI().getPath();auth=exchange.getRequestHeaders().getFirst("Authorization");
            request=new String(exchange.getRequestBody().readAllBytes(),StandardCharsets.UTF_8);
            String c=content.get();
            String escaped=c.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n");
            byte[] bytes=("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\""+escaped+"\"}}]}").getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type","application/json");exchange.sendResponseHeaders(status,bytes.length);
            exchange.getResponseBody().write(bytes);exchange.close();
        });server.start();return Map.of("coffee.chat-url","http://127.0.0.1:"+server.getAddress().getPort()+"/llm/demo/v1/chat/completions","coffee.api-key","test-only-secret","coffee.model","test-model","coffee.json-mode","true");
    }catch(Exception e){throw new RuntimeException(e);}}
    public void stop(){if(server!=null)server.stop(0);}
}
