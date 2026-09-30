package be.devoxx.coffee;

import io.smallrye.config.ConfigSourceInterceptor;
import io.smallrye.config.ConfigSourceInterceptorContext;
import io.smallrye.config.ConfigValue;
import io.smallrye.config.Priorities;
import jakarta.annotation.Priority;

/**
 * Keeps the demo's {@code coffee.chat-url} / {@code AI_CHAT_URL} full chat-completions URL
 * while feeding Quarkus LangChain4j the OpenAI-compatible base URL it expects.
 */
@Priority(Priorities.LIBRARY + 300)
public class CoffeeOpenAiConfigInterceptor implements ConfigSourceInterceptor {
    @Override
    public ConfigValue getValue(ConfigSourceInterceptorContext context, String name) {
        // Prefer coffee.chat-url so AI_CHAT_URL keeps working; the OpenAI extension default
        // (api.openai.com) must not win when a demo endpoint is configured.
        if ("quarkus.langchain4j.openai.base-url".equals(name)) {
            ConfigValue chatUrl = context.proceed("coffee.chat-url");
            if (chatUrl != null && chatUrl.getValue() != null && !chatUrl.getValue().isBlank()) {
                return chatUrl.withValue(toOpenAiBaseUrl(chatUrl.getValue()));
            }
            return context.proceed(name);
        }
        if ("quarkus.langchain4j.openai.chat-model.response-format".equals(name)) {
            ConfigValue explicit = context.proceed(name);
            if (explicit != null && explicit.getValue() != null && !explicit.getValue().isBlank()) {
                return explicit;
            }
            ConfigValue jsonMode = context.proceed("coffee.json-mode");
            if (jsonMode != null && Boolean.parseBoolean(jsonMode.getValue())) {
                return ConfigValue.builder()
                    .withName(name)
                    .withValue("json_object")
                    .withRawValue("json_object")
                    .withConfigSourceName("CoffeeOpenAiConfigInterceptor")
                    .build();
            }
        }
        return context.proceed(name);
    }

    static String toOpenAiBaseUrl(String chatUrl) {
        String u = chatUrl.trim();
        String suffix = "/chat/completions";
        if (u.endsWith(suffix)) {
            u = u.substring(0, u.length() - suffix.length());
        }
        return u.endsWith("/") ? u : u + "/";
    }
}
