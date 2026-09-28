using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using MultiTenantApi.Auth;
using MultiTenantApi.Models;
using MultiTenantApi.Processing;

var builder = WebApplication.CreateBuilder(args);

// Jwt__SigningKey is injected from AWS Secrets Manager by the ECS task definition.
var signingKey = builder.Configuration["Jwt:SigningKey"]
    ?? throw new InvalidOperationException(
        "Jwt:SigningKey is not configured (set the Jwt__SigningKey environment variable)");

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = builder.Configuration["Jwt:Issuer"],
            ValidateAudience = true,
            ValidAudience = builder.Configuration["Jwt:Audience"],
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(signingKey)),
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(30),
        };
    });

builder.Services.AddAuthorization();
builder.Services.AddSingleton<TenantResolver>();
builder.Services.AddSingleton<DevTokenIssuer>();
builder.Services.AddSingleton<SettlementProcessor>();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// --- Operational endpoints -------------------------------------------------

app.MapGet("/health", () => Results.Ok(new { status = "ok" }))
   .AllowAnonymous();

// --- Lab identity provider -------------------------------------------------

if (app.Configuration.GetValue("Lab:EnableDevTokenEndpoint", false))
{
    app.MapPost("/dev/token", (DevTokenRequest request, DevTokenIssuer issuer) =>
        string.IsNullOrWhiteSpace(request.TenantId)
            ? Results.BadRequest(new { error = "tenantId is required" })
            : Results.Ok(issuer.Issue(request)))
       .AllowAnonymous();
}

// --- Business endpoints ----------------------------------------------------

app.MapPost("/api/v1/settlements", async (
        HttpRequest httpRequest,
        SettlementRequest body,
        TenantResolver resolver,
        SettlementProcessor processor,
        CancellationToken cancellationToken) =>
    {
        // The tenant identity is decoded here, from the bearer token, and then
        // flows through the call as a plain argument. No span tagging anywhere.
        var tenant = resolver.Resolve(httpRequest);

        try
        {
            var result = await processor.SettleAsync(tenant, body, cancellationToken);
            return Results.Ok(result);
        }
        catch (InvalidOperationException ex)
        {
            return Results.Problem(title: "settlement_rejected", detail: ex.Message, statusCode: 402);
        }
    })
   .RequireAuthorization();

app.MapGet("/api/v1/settlements/{settlementId}", (
        string settlementId,
        HttpRequest httpRequest,
        TenantResolver resolver,
        SettlementProcessor processor) =>
    {
        var tenant = resolver.Resolve(httpRequest);
        var result = processor.Lookup(settlementId);

        // Tenant isolation: never hand one tenant another tenant's settlement.
        if (result is null || result.TenantId != tenant.TenantId)
        {
            return Results.NotFound();
        }

        return Results.Ok(result);
    })
   .RequireAuthorization();

app.Run();
