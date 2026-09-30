package be.devoxx.coffee;
import com.sun.net.httpserver.HttpServer;
import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
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
            byte[] bytes;
            if(status==200) {
                String c=content.get();
                String escaped=c.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n");
                // Quarkus LangChain4j requires a non-null ChatCompletionResponse.id
                bytes=("{\"id\":\"chatcmpl-test\",\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\""+escaped+"\"}}]}").getBytes(StandardCharsets.UTF_8);
            } else {
                bytes="{\"error\":{\"message\":\"busy\",\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\"}}".getBytes(StandardCharsets.UTF_8);
            }
            exchange.getResponseHeaders().set("Content-Type","application/json");exchange.sendResponseHeaders(status,bytes.length);
            exchange.getResponseBody().write(bytes);exchange.close();
        });server.start();
        String base="http://127.0.0.1:"+server.getAddress().getPort()+"/llm/demo/v1/";
        Map<String,String> cfg=new HashMap<>();
        cfg.put("coffee.chat-url",base+"chat/completions");
        cfg.put("coffee.api-key","test-only-secret");
        cfg.put("coffee.model","test-model");
        cfg.put("coffee.json-mode","true");
        cfg.put("quarkus.langchain4j.openai.base-url",base);
        cfg.put("quarkus.langchain4j.openai.api-key","test-only-secret");
        cfg.put("quarkus.langchain4j.openai.chat-model.model-name","test-model");
        cfg.put("quarkus.langchain4j.openai.chat-model.response-format","json_object");
        cfg.put("quarkus.langchain4j.openai.max-retries","1");
        return cfg;
    }catch(Exception e){throw new RuntimeException(e);}}
    public void stop(){if(server!=null)server.stop(0);}
}
