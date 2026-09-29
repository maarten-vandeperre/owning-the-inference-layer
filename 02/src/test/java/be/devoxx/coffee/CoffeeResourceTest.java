package be.devoxx.coffee;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.common.QuarkusTestResource;
import jakarta.ws.rs.WebApplicationException;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import java.net.URI;
import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.*;
import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest @QuarkusTestResource(MockModel.class)
class CoffeeResourceTest {
    private static final String LATTE="{\"drink\":\"latte\",\"size\":\"large\",\"milk\":\"oat\",\"quantity\":2,\"decaf\":false,\"unitCents\":1}";
    private static final String CAPPUCCINO="{\"drink\":\"cappuccino\",\"size\":\"regular\",\"milk\":\"dairy\",\"quantity\":1,\"decaf\":false}";
    private static String cart(String items) {return "{\"items\":["+items+"],\"clarification\":\"\",\"totalCents\":1}";}
    @BeforeEach void reset() {MockModel.status=200; MockModel.content.set(cart(LATTE+","+CAPPUCCINO));}
    private io.restassured.response.ValidatableResponse interpret() {
        return given().contentType("application/json").body("{\"text\":\"Two large oat lattes and a cappuccino, please.\"}").post("/api/interpret").then();
    }
    @Test void pricesEveryDrinkAndConfirmsTheWholeOrderIdempotently() {
        var result=interpret().statusCode(200).body("quote.items.size()",equalTo(2))
            .body("quote.items[0].quantity",equalTo(2)).body("quote.items[0].unitCents",equalTo(510))
            .body("quote.items[0].totalCents",equalTo(1020)).body("quote.items[1].drink",equalTo("cappuccino"))
            .body("quote.items[1].totalCents",equalTo(380)).body("quote.totalCents",equalTo(1400));
        String quote=result.extract().path("quote.id");
        assertEquals("Bearer test-only-secret",MockModel.auth);
        assertEquals("/llm/demo/v1/chat/completions",MockModel.path);
        assertTrue(MockModel.request.contains("test-model"));
        assertTrue(MockModel.request.contains("Include EVERY requested drink"));
        var request=given().contentType("application/json").body("{\"quoteId\":\""+quote+"\",\"items\":[],\"totalCents\":1}");
        String id=request.post("/api/orders").then().statusCode(200).body("items.size()",equalTo(2))
            .body("items[0].quantity",equalTo(2)).body("items[1].drink",equalTo("cappuccino"))
            .body("totalCents",equalTo(1400)).extract().path("id");
        request.post("/api/orders").then().statusCode(200).body("id",equalTo(id)).body("totalCents",equalTo(1400));
    }
    @Test void singleDrinkOrdersStillWork() {
        MockModel.content.set(cart(LATTE));interpret().statusCode(200).body("quote.items.size()",equalTo(1)).body("quote.totalCents",equalTo(1020));
    }
    @Test void preservesVariantsOfTheSameDrink() {
        MockModel.content.set(cart(LATTE+","+LATTE.replace("oat","soy").replace("false","true")));
        interpret().statusCode(200).body("quote.items.size()",equalTo(2)).body("quote.items[0].milk",equalTo("oat"))
            .body("quote.items[1].milk",equalTo("soy")).body("quote.items[1].decaf",equalTo(true)).body("quote.totalCents",equalTo(2040));
    }
    @Test void combinesIdenticalLinesWithoutLosingQuantity() {
        MockModel.content.set(cart(LATTE+","+LATTE));interpret().statusCode(200).body("quote.items.size()",equalTo(1))
            .body("quote.items[0].quantity",equalTo(4)).body("quote.totalCents",equalTo(2040));
    }
    @Test void acceptsExactlySixCupsAcrossDifferentLines() {
        MockModel.content.set(cart(LATTE+","+CAPPUCCINO.replace(":1,",":4,")));
        interpret().statusCode(200).body("quote.totalCents",equalTo(2540));
    }
    @Test void enforcesTotalCupLimitAcrossIndividuallyValidLines() {
        MockModel.content.set(cart(LATTE+","+CAPPUCCINO.replace(":1,",":5,")));
        interpret().statusCode(502).body("error",containsString("six cups in total"));
    }
    @Test void clarificationPreventsPartialOrder() {
        MockModel.content.set("{\"items\":["+LATTE+"],\"clarification\":\"Which drink should accompany the lattes?\"}");
        interpret().statusCode(200).body("quote",nullValue()).body("clarification",containsString("Which drink"));
    }
    @Test void invalidSecondItemRejectsWholeOrder() {
        MockModel.content.set(cart(LATTE+","+CAPPUCCINO.replace("cappuccino","champagne")));interpret().statusCode(502);
    }
    @ParameterizedTest @ValueSource(strings={"0","7","-1","1.5","\"2\"","null","4294967298"})
    void rejectsInvalidQuantityTypesAndBounds(String value) {
        MockModel.content.set(cart(LATTE.replace("\"quantity\":2","\"quantity\":"+value)));interpret().statusCode(502);
    }
    @ParameterizedTest @ValueSource(strings={"[]","{}","null","\"latte\""})
    void rejectsMissingOrInvalidItemArrays(String items) {
        MockModel.content.set("{\"items\":"+items+",\"clarification\":\"\"}");interpret().statusCode(502);
    }
    @Test void rejectsTooManyItemLines() {
        MockModel.content.set(cart(String.join(",",java.util.Collections.nCopies(7,CAPPUCCINO))));interpret().statusCode(502);
    }
    @Test void rejectsInvalidEspressoVariant() {
        MockModel.content.set(cart(CAPPUCCINO.replace("cappuccino","espresso")));interpret().statusCode(502);
    }
    @Test void rejectsBrokenJson() {MockModel.content.set("I placed the order already!");interpret().statusCode(502);}
    @Test void rejectsNonBooleanDecaf() {MockModel.content.set(cart(LATTE.replace("false","\"false\"")));interpret().statusCode(502);}
    @Test void unknownQuoteCannotBeOrdered() {
        given().contentType("application/json").body("{\"quoteId\":\"made-up\"}").post("/api/orders").then().statusCode(410);
    }
    @Test void handlesQuotaAndDoesNotLeakSecrets() {
        MockModel.status=429;interpret().statusCode(429).body("error",not(containsString("test-only-secret")));
        given().get("/api/config").then().statusCode(200).body(not(containsString("test-only-secret")));
    }
    @Test void rejectsEmptyOrder() {
        given().contentType("application/json").body("{\"text\":\" \"}").post("/api/interpret").then().statusCode(400);
    }
    @Test void allowsOnlyExplicitContainerHttpHosts() {
        assertDoesNotThrow(()->CoffeeResource.validateEndpoint(URI.create("https://maas.example.test/v1/chat/completions"),""));
        assertDoesNotThrow(()->CoffeeResource.validateEndpoint(URI.create("http://127.0.0.1:8099/v1/chat/completions"),""));
        assertDoesNotThrow(()->CoffeeResource.validateEndpoint(URI.create("http://host.containers.internal:8081/v1/chat/completions"),"host.containers.internal"));
        assertDoesNotThrow(()->CoffeeResource.validateEndpoint(URI.create("http://mock-model:8099/v1/chat/completions"),"mock-model"));
        var failure=assertThrows(WebApplicationException.class,()->CoffeeResource.validateEndpoint(URI.create("http://maas.example.test/v1/chat/completions"),"host.containers.internal"));
        assertEquals(503,failure.getResponse().getStatus());
        assertThrows(WebApplicationException.class,()->CoffeeResource.validateEndpoint(URI.create("http://host.containers.internal.evil.test/v1/chat/completions"),"host.containers.internal"));
    }
}
