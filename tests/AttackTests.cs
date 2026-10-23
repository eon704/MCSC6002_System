#:package System.IdentityModel.Tokens.Jwt@8.19.2
#:property PublishAot=false
// Security test suite: runs attack cases against the live local stack and prints a results table.
// Prerequisites: `docker compose up -d`, then all four services running with `dotnet run --launch-profile https`.
// Usage (from MCSC6002_System): dotnet run tests/AttackTests.cs
// Uses ../keys (JWT private key to mint expired/forged tokens, gateway client cert for direct service calls) and .env.
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

const string Gateway = "https://localhost:7000";
const string Identity = "https://localhost:7284";
const string EventType = "ResponseLibrary.Models.Requests.Product.Events.ProductCreatedEvent";

var env = File.ReadAllLines(".env")
    .Where(l => l.Contains('=') && !l.TrimStart().StartsWith('#'))
    .Select(l => l.Split('=', 2))
    .ToDictionary(p => p[0].Trim(), p => p[1].Trim());

HttpClient NewClient(X509Certificate2? clientCertificate = null)
{
    var handler = new SocketsHttpHandler();
    handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, _) => true; // Test client only: local dev certificates.
    if (clientCertificate is not null) handler.SslOptions.ClientCertificates = new X509CertificateCollection { clientCertificate };
    return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };
}

var client = NewClient();
// Trusted internal caller (gateway's client cert): used for direct service tests and to avoid the gateway's login rate limit.
var asGateway = NewClient(X509CertificateLoader.LoadPkcs12FromFile("../keys/tls/gateway-client.pfx", null));

var results = new List<string[]>();
void Check(string id, string threat, string name, string expected, string actual, bool pass)
{
    results.Add([id, threat, name, expected, actual, pass ? "PASS" : "FAIL"]);
    Console.WriteLine($"{(pass ? "PASS" : "FAIL")}  {id,-4} {name} -> {actual}");
}

async Task<(int Status, string Body, HttpResponseMessage? Response)> Send(HttpClient c, HttpMethod method, string url, string? token = null, object? body = null)
{
    var request = new HttpRequestMessage(method, url);
    if (token is not null) request.Headers.Authorization = new("Bearer", token);
    if (body is not null) request.Content = body is string raw ? new StringContent(raw, Encoding.UTF8, "application/json") : JsonContent.Create(body);
    try
    {
        var response = await c.SendAsync(request);
        return ((int)response.StatusCode, await response.Content.ReadAsStringAsync(), response);
    }
    catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
    {
        return (0, "connection rejected: " + (e.InnerException?.Message ?? e.Message), null);
    }
}

string Message(string body)
{
    try { return JsonNode.Parse(body)?["messages"]?[0]?.ToString() ?? (body.Length > 60 ? body[..60] : body); }
    catch { return body.Length > 60 ? body[..60] : body; }
}

string Show((int Status, string Body, HttpResponseMessage? Response) r) => r.Status == 0 ? r.Body[..Math.Min(r.Body.Length, 70)] : $"{r.Status} {Message(r.Body)}".Trim();

async Task<JsonNode?> Login(HttpClient c, string url, string user, string password)
{
    var r = await Send(c, HttpMethod.Post, url, body: new { userName = user, password });
    return r.Status == 200 ? JsonNode.Parse(r.Body)?["data"] : null;
}

// Token minting with the real private key (to test expiry/algorithm handling) and with keys an attacker might have.
var rsa = RSA.Create();
rsa.ImportFromPem(File.ReadAllText("../keys/jwt-private.pem"));
string Mint(SigningCredentials credentials, DateTime expires, params string[] permissions)
{
    var claims = new List<Claim> { new(ClaimTypes.Email, "admin@cloudbase.com") };
    claims.AddRange(permissions.Select(p => new Claim("permission", p)));
    return new JwtSecurityTokenHandler().WriteToken(new JwtSecurityToken("authlibrary_identity", "authlibrary_services", claims, DateTime.UtcNow.AddHours(-1), expires, credentials));
}
string B64Url(string json) => Base64UrlEncoder.Encode(json);

const string ProductsAll = Gateway + "/product-service/products/all";
const string ProductsCreate = Gateway + "/product-service/products/create";
const string UsersCreate = Gateway + "/identity/users/create";

// ---------- Setup ----------
var admin = await Login(client, Gateway + "/auth/login", "admin@cloudbase.com", env["SEED_ADMIN_PASSWORD"]);      // /auth call 1
var basic = await Login(client, Gateway + "/auth/login", "basic@cloudbase.com", env["SEED_BASIC_PASSWORD"]);      // /auth call 2
if (admin is null || basic is null) { Console.WriteLine("Setup failed: cannot log in (is basic@cloudbase.com locked out?)."); return 1; }
var adminToken = admin["token"]!.ToString();
var basicToken = basic["token"]!.ToString();

await Send(client, HttpMethod.Post, Gateway + "/product-service/brands/create", adminToken, new { name = "TestBrand", description = "security tests" });
var brands = JsonNode.Parse((await Send(client, HttpMethod.Get, Gateway + "/product-service/brands/all", adminToken)).Body)!["data"]!.AsArray();
var brandId = brands.Max(b => (int)b!["id"]!);
object ProductBody(string name, object quantity, string description = "") => new { brandId, name, description, quantity, reOrderThreshold = 0 };

// ---------- Authentication and access control ----------
var r = await Send(client, HttpMethod.Get, ProductsAll);
Check("A1", "S1", "No token", "401", Show(r), r.Status == 401);

var parts = basicToken.Split('.');
var forgedPayload = Base64UrlEncoder.Decode(parts[1]).Replace("Permission.Product.Products.Read", "Permission.Product.Products.Create");
r = await Send(client, HttpMethod.Post, ProductsCreate, $"{parts[0]}.{B64Url(forgedPayload)}.{parts[2]}", ProductBody("Forged", 1));
Check("A2", "T1", "Edited token payload (add Create permission)", "401", Show(r), r.Status == 401);

var noneToken = $"{B64Url("{\"alg\":\"none\",\"typ\":\"JWT\"}")}.{parts[1]}.";
r = await Send(client, HttpMethod.Get, ProductsAll, noneToken);
Check("A3", "S2", "alg=none token", "401", Show(r), r.Status == 401);

var hs256 = Mint(new SigningCredentials(new SymmetricSecurityKey(Encoding.UTF8.GetBytes("ao787VuHniutbig8ob5cf000pju787jlpzDD0")), SecurityAlgorithms.HmacSha256), DateTime.UtcNow.AddMinutes(10), "Permission.Product.Products.Read");
r = await Send(client, HttpMethod.Get, ProductsAll, hs256);
Check("A4", "S1", "HS256 token signed with old leaked secret", "401", Show(r), r.Status == 401);

var rs384 = Mint(new SigningCredentials(new RsaSecurityKey(rsa), SecurityAlgorithms.RsaSha384), DateTime.UtcNow.AddMinutes(10), "Permission.Product.Products.Read");
r = await Send(client, HttpMethod.Get, ProductsAll, rs384);
Check("A5", "S2", "RS384 token signed with the real key", "401", Show(r), r.Status == 401);

var expired = Mint(new SigningCredentials(new RsaSecurityKey(rsa), SecurityAlgorithms.RsaSha256), DateTime.UtcNow.AddMinutes(-1), "Permission.Product.Products.Read");
r = await Send(client, HttpMethod.Get, ProductsAll, expired);
Check("A6", "E2", "Expired RS256 token", "401", Show(r), r.Status == 401);

r = await Send(client, HttpMethod.Post, ProductsCreate, basicToken, ProductBody("ByBasic", 1));
Check("A7", "E1", "Basic user creates a product", "403", Show(r), r.Status == 403);

r = await Send(client, HttpMethod.Get, ProductsAll, basicToken);
Check("A8", "E1", "Basic user reads products (allowed)", "200", $"{r.Status}", r.Status == 200);

var refresh = await Send(client, HttpMethod.Post, Gateway + "/auth/refresh-token", body: new { token = basicToken, refreshToken = basic["refreshToken"]!.ToString() }); // /auth call 3
var reuse = await Send(client, HttpMethod.Post, Gateway + "/auth/refresh-token", body: new { token = basicToken, refreshToken = basic["refreshToken"]!.ToString() });   // /auth call 4
Check("A9", "E3", "Refresh rotates; old refresh token reused", "200 then 400", $"{refresh.Status} then {Show(reuse)}", refresh.Status == 200 && reuse.Status == 400);

var wrong = await Send(client, HttpMethod.Post, Gateway + "/auth/login", body: new { userName = "admin@cloudbase.com", password = "wrong-password" }); // /auth call 5
var unknown = await Send(asGateway, HttpMethod.Post, Identity + "/api/token/login", body: new { userName = "nobody@cloudbase.com", password = "wrong-password" });
Check("A10", "S4", "Wrong password vs unknown user", "same generic message", $"'{Message(wrong.Body)}' / '{Message(unknown.Body)}'", Message(wrong.Body) == Message(unknown.Body));

r = await Send(client, HttpMethod.Post, Gateway + "/auth/login", body: new { userName = "admin@cloudbase.com", password = "wrong-password" }); // /auth call 6
Check("A11", "S4", "6th login attempt in one minute (rate limit)", "429", Show(r), r.Status == 429);

var suffix = Random.Shared.Next(100000, 999999);
var testUser = $"test{suffix}";
var testPassword = $"Correct horse {suffix}";
object UserBody(string password) => new { firstName = "Test", lastName = "User", email = $"{testUser}@cloudbase.com", userName = testUser, password, confirmPassword = password, phoneNumber = "5551234567", autoConfirmEmail = true, activateUser = true };
r = await Send(client, HttpMethod.Post, UsersCreate, adminToken, UserBody("short1"));
var weak = await Send(client, HttpMethod.Post, UsersCreate, adminToken, UserBody("aaaaaaaaaaaa"));
Check("A12", "S4", "Create user with weak passwords", "400, 400", $"{Show(r)} / {Show(weak)}", r.Status == 400 && weak.Status == 400);

r = await Send(client, HttpMethod.Post, UsersCreate, adminToken, UserBody(testPassword));
var firstLogin = await Login(asGateway, Identity + "/api/token/login", testUser, testPassword);
for (var i = 0; i < 5; i++) await Send(asGateway, HttpMethod.Post, Identity + "/api/token/login", body: new { userName = testUser, password = "wrong-password" });
var lockedLogin = await Login(asGateway, Identity + "/api/token/login", testUser, testPassword);
Check("A13", "S4", "5 wrong passwords, then the correct one", "correct password rejected", $"before: {(firstLogin is null ? "rejected" : "ok")}, after: {(lockedLogin is null ? "rejected" : "ok")}", firstLogin is not null && lockedLogin is null);

// Direct to Identity: the gateway's /auth/* limit is used up by A11.
var session = await Login(asGateway, Identity + "/api/token/login", "basic@cloudbase.com", env["SEED_BASIC_PASSWORD"]);
var revoke = await Send(asGateway, HttpMethod.Post, Identity + "/api/token/revoke", session!["token"]!.ToString());
r = await Send(asGateway, HttpMethod.Post, Identity + "/api/token/refresh-token", body: new { token = session["token"]!.ToString(), refreshToken = session["refreshToken"]!.ToString() });
Check("A14", "E3", "Refresh after logout (revoke)", "200 then 400", $"{revoke.Status} then {Show(r)}", revoke.Status == 200 && r.Status == 400);

// ---------- Service-to-service transport ----------
r = await Send(client, HttpMethod.Post, Identity + "/api/token/login", body: new { userName = "admin@cloudbase.com", password = "x" });
Check("N1", "S3", "Direct call to a service, no client cert", "TLS handshake rejected", Show(r), r.Status == 0);

var rogueKey = RSA.Create(2048);
var rogueRequest = new CertificateRequest("CN=api-gateway", rogueKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
rogueRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.2")], false));
var rogue = X509CertificateLoader.LoadPkcs12(rogueRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1)).Export(X509ContentType.Pfx), null);
r = await Send(NewClient(rogue), HttpMethod.Post, Identity + "/api/token/login", body: new { userName = "admin@cloudbase.com", password = "x" });
Check("N2", "S3", "Direct call, self-signed cert CN=api-gateway", "TLS handshake rejected", Show(r), r.Status == 0);

r = await Send(client, HttpMethod.Get, "http://localhost:5044/api/token/login");
Check("N3", "T2", "Plain HTTP to a service (old HTTP port)", "no listener", Show(r), r.Status == 0);

async Task<bool> PortOpen(int port)
{
    using var tcp = new System.Net.Sockets.TcpClient();
    try { await tcp.ConnectAsync("127.0.0.1", port); return true; }
    catch (System.Net.Sockets.SocketException) { return false; }
}
var projectCa = X509CertificateLoader.LoadCertificateFromFile("../keys/tls/ca.crt");
var brokerCertificate = "no TLS";
using (var tcp = new System.Net.Sockets.TcpClient())
{
    await tcp.ConnectAsync("127.0.0.1", 5671);
    using var tls = new System.Net.Security.SslStream(tcp.GetStream(), false, (_, certificate, _, _) =>
    {
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        chain.ChainPolicy.CustomTrustStore.Add(projectCa);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        brokerCertificate = certificate is X509Certificate2 c && chain.Build(c) ? "project CA" : "untrusted";
        return true;
    });
    await tls.AuthenticateAsClientAsync("localhost");
    brokerCertificate += $", {tls.SslProtocol}";
}
var plainAmqp = await PortOpen(5672);
Check("N4", "T3", "RabbitMQ: plain AMQP port, then TLS port", "5672 closed; 5671 TLS, project CA", $"5672 {(plainAmqp ? "open" : "closed")}; 5671 {brokerCertificate}", !plainAmqp && brokerCertificate.StartsWith("project CA"));

// ---------- Input validation ----------
r = await Send(asGateway, HttpMethod.Post, Identity + "/api/token/login", body: new { userName = "' OR '1'='1' --", password = "' OR '1'='1' --" });
Check("V1", "T4", "SQL injection in login", "rejected, no 500", Show(r), r.Status == 400);

const string SqlName = "x'); DROP TABLE Products;--";
r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody(SqlName, 1));
var sqlProduct = r.Status == 200 ? await Send(client, HttpMethod.Get, $"{Gateway}/product-service/products/{JsonNode.Parse(r.Body)!["data"]}", adminToken) : r;
var all = await Send(client, HttpMethod.Get, ProductsAll, adminToken);
Check("V2", "T4", "SQL injection as product name", "stored as text, table intact", $"create {r.Status}, list {all.Status}, literal stored: {sqlProduct.Body.Contains("DROP TABLE")}", r.Status == 200 && all.Status == 200 && sqlProduct.Body.Contains("DROP TABLE"));

Check("V2b", "-", "New product appears in the cached product list", "listed", $"listed: {all.Body.Contains("DROP TABLE")}", all.Body.Contains("DROP TABLE"));

r = await Send(client, HttpMethod.Get, Gateway + "/product-service/products/1%20OR%201=1", adminToken);
Check("V3", "T4", "SQL injection in route id", "400/404, no data", Show(r), r.Status is 400 or 404);

r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("Long", 1, new string('A', 10_000)));
Check("V4", "D3", "Oversized description (10,000 chars)", "400", Show(r), r.Status == 400);

r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("Huge", 5000));
var negative = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("Negative", -1));
Check("V5", "D1", "Quantity 5000 and -1", "400, 400", $"{Show(r)} / {negative.Status}", r.Status == 400 && negative.Status == 400);

r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, $"{{\"brandId\":{brandId},\"name\":\"Type\",\"quantity\":\"abc\",\"reOrderThreshold\":0}}");
Check("V6", "T4", "Wrong type (quantity = \"abc\")", "400", $"{r.Status}", r.Status == 400);

r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("<script>alert(1)</script>", 1));
all = await Send(client, HttpMethod.Get, ProductsAll, adminToken);
var contentType = all.Response?.Content.Headers.ContentType?.MediaType;
Check("V7", "T4", "XSS payload as product name", "stored as data, served as JSON", $"create {r.Status}, served as {contentType}", contentType == "application/json");

r = await Send(client, HttpMethod.Put, Gateway + "/inventory-service/items/change-item-status", adminToken, new { id = 1, status = "<script>" });
Check("V8", "T4", "Unknown inventory status", "rejected", Show(r), r.Status is 400 or 404 && r.Body.Contains("Status must be"));

var underLimit = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("Big", 1, new string('A', 1024 * 1024)));
r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, ProductBody("Big", 1, new string('A', 3 * 1024 * 1024)));
// Kestrel answers 413 and closes the connection, so the client usually sees a reset mid-upload.
Check("V9", "D3", "1 MB vs 3 MB request body (2 MB limit)", "400 (validator), then 413/reset", $"{underLimit.Status}, then {Show(r)}", underLimit.Status == 400 && r.Status is 413 or 0);

// ---------- Messaging (attacker with RabbitMQ credentials publishes directly) ----------
var signingKey = Convert.FromBase64String(env["MESSAGE_SIGNING_KEY"]);
var rabbit = new HttpClient();
rabbit.DefaultRequestHeaders.Authorization = new("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{env["RABBITMQ_USER"]}:{env["RABBITMQ_PASSWORD"]}")));
string Sign(object evt, string signedAt) => Convert.ToBase64String(HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes($"{EventType}|{signedAt}|{JsonSerializer.Serialize(evt)}")));
object Event(int id, int quantity) => new { Id = id, Name = "attack", Quantity = quantity, ReOrderThreshold = 0 };

async Task PublishRaw(object evt, Dictionary<string, string> headers)
{
    var envelope = new { messageId = Guid.NewGuid(), messageType = new[] { "urn:message:ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent" }, message = evt, headers };
    await rabbit.PostAsJsonAsync("http://127.0.0.1:15672/api/exchanges/%2F/ResponseLibrary.Models.Requests.Product.Events:ProductCreatedEvent/publish",
        new { properties = new { content_type = "application/vnd.masstransit+json", headers }, routing_key = "", payload = JsonSerializer.Serialize(envelope), payload_encoding = "string" });
}

var baseId = Random.Shared.Next(100_000, 900_000);
var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
var old = DateTimeOffset.UtcNow.AddMinutes(-10).ToUnixTimeSeconds().ToString();
var cases = new (string Id, string Threat, string Name, int ProductId, object Sent, Dictionary<string, string> Headers, int ExpectedItems)[]
{
    ("M1", "S5", "Unsigned event", baseId + 1, Event(baseId + 1, 3), new(), 0),
    ("M2", "T3", "Signed for qty 1, sent with qty 500", baseId + 2, Event(baseId + 2, 500), new() { ["X-Signed-At"] = now, ["X-Signature"] = Sign(Event(baseId + 2, 1), now) }, 0),
    ("M3", "T3", "Replay of a 10-minute-old signed event", baseId + 3, Event(baseId + 3, 2), new() { ["X-Signed-At"] = old, ["X-Signature"] = Sign(Event(baseId + 3, 2), old) }, 0),
    ("M4", "D1", "Validly signed, qty 5000", baseId + 4, Event(baseId + 4, 5000), new() { ["X-Signed-At"] = now, ["X-Signature"] = Sign(Event(baseId + 4, 5000), now) }, 0),
    ("M5", "-", "Validly signed, qty 2 (control)", baseId + 5, Event(baseId + 5, 2), new() { ["X-Signed-At"] = now, ["X-Signature"] = Sign(Event(baseId + 5, 2), now) }, 2),
};
foreach (var c in cases) await PublishRaw(c.Sent, c.Headers);
await Task.Delay(TimeSpan.FromSeconds(5)); // Let the consumer process them.
foreach (var c in cases)
{
    var items = await Send(client, HttpMethod.Get, $"{Gateway}/inventory-service/items/get-by-product-id/{c.ProductId}", adminToken);
    var count = items.Status == 200 ? JsonNode.Parse(items.Body)!["data"]!.AsArray().Count : 0;
    Check(c.Id, c.Threat, c.Name, c.ExpectedItems == 0 ? "rejected, 0 items" : $"accepted, {c.ExpectedItems} items", $"{count} items", count == c.ExpectedItems);
}

// ---------- Information disclosure ----------
r = await Send(client, HttpMethod.Get, ProductsAll, adminToken);
var server = r.Response?.Headers.TryGetValues("Server", out var values) == true ? string.Join(",", values) : "(none)";
Check("I1", "I3", "Server header on a proxied response", "(none)", server, server == "(none)");

string HeaderValue(string name) => r.Response is null ? "" :
    r.Response.Headers.TryGetValues(name, out var v) || r.Response.Content.Headers.TryGetValues(name, out v) ? string.Join(",", v) : "(none)";
var securityHeaders = $"nosniff={HeaderValue("X-Content-Type-Options")}, CORP={HeaderValue("Cross-Origin-Resource-Policy")}, cache={HeaderValue("Cache-Control")}";
Check("I3", "I1", "API security headers", "nosniff, same-origin, no-store", securityHeaders,
    HeaderValue("X-Content-Type-Options") == "nosniff" && HeaderValue("Cross-Origin-Resource-Policy") == "same-origin" && HeaderValue("Cache-Control") == "no-store");

r = await Send(client, HttpMethod.Get, Gateway + "/");
Check("I4", "I3", "Static page at / (technology fingerprint)", "404", $"{r.Status}", r.Status == 404);

r = await Send(client, HttpMethod.Post, ProductsCreate, adminToken, "{ not json");
Check("I2", "I1", "Malformed JSON body", "400, no stack trace", $"{r.Status}, stack trace: {r.Body.Contains("   at ")}", r.Status == 400 && !r.Body.Contains("   at "));

// ---------- Summary ----------
Console.WriteLine();
Console.WriteLine("| ID | Threat | Case | Expected | Actual | Result |");
Console.WriteLine("|---|---|---|---|---|---|");
foreach (var row in results) Console.WriteLine($"| {string.Join(" | ", row.Select(v => v.Replace("|", "/")))} |");
var failed = results.Count(row => row[5] == "FAIL");
Console.WriteLine($"\n{results.Count - failed}/{results.Count} passed.");
return failed == 0 ? 0 : 1;
