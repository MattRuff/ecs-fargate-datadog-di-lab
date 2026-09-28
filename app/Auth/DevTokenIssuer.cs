using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Microsoft.IdentityModel.Tokens;
using MultiTenantApi.Models;

namespace MultiTenantApi.Auth;

/// <summary>
/// Lab-only stand-in for the customer's identity provider. Mints HS256 tokens
/// carrying a tenant_id claim so the load generator can impersonate tenants
/// without standing up Auth0/Entra/Cognito. Disabled by setting
/// Lab:EnableDevTokenEndpoint=false.
/// </summary>
public sealed class DevTokenIssuer
{
    private readonly SigningCredentials _credentials;
    private readonly string _issuer;
    private readonly string _audience;

    public DevTokenIssuer(IConfiguration configuration)
    {
        var signingKey = configuration["Jwt:SigningKey"]
            ?? throw new InvalidOperationException("Jwt:SigningKey is not configured");

        _credentials = new SigningCredentials(
            new SymmetricSecurityKey(Encoding.UTF8.GetBytes(signingKey)),
            SecurityAlgorithms.HmacSha256);

        _issuer = configuration["Jwt:Issuer"]!;
        _audience = configuration["Jwt:Audience"]!;
    }

    public DevTokenResponse Issue(DevTokenRequest request)
    {
        var plan = request.Plan is { Length: > 0 } p && PlanCatalog.IsKnown(p)
            ? p
            : PlanCatalog.DefaultPlan;

        var ttl = TimeSpan.FromMinutes(Math.Clamp(request.TtlMinutes ?? 60, 1, 1440));
        var now = DateTime.UtcNow;

        var claims = new List<Claim>
        {
            new("sub", $"svc-{request.TenantId}"),
            new("jti", Guid.NewGuid().ToString("n")),
            new(TenantResolver.TenantIdClaim, request.TenantId),
            new(TenantResolver.PlanClaim, plan),
        };

        var token = new JwtSecurityToken(
            issuer: _issuer,
            audience: _audience,
            claims: claims,
            notBefore: now,
            expires: now.Add(ttl),
            signingCredentials: _credentials);

        return new DevTokenResponse(
            AccessToken: new JwtSecurityTokenHandler().WriteToken(token),
            TokenType: "Bearer",
            ExpiresInSeconds: (int)ttl.TotalSeconds);
    }
}
