using System.IdentityModel.Tokens.Jwt;
using MultiTenantApi.Models;

namespace MultiTenantApi.Auth;

/// <summary>
/// Turns the bearer token on the inbound request into a <see cref="TenantContext"/>.
///
/// THIS IS THE PROBE SEAM.
///
/// The customer scenario is: "the only identifier we have is a tenant_id claim
/// inside the JWT in the Authorization header, the JWT has to be decoded to be
/// useful, and we are not adding any instrumentation code to get it onto spans."
///
/// So the application decodes the JWT for its own reasons (it needs the tenant to
/// pick a price list and to partition data), and Datadog Dynamic Instrumentation
/// attaches to this method at runtime to lift the decoded value onto the span.
/// Nothing in this file is Datadog-aware. See docs/dynamic-instrumentation.md.
/// </summary>
public sealed class TenantResolver
{
    public const string TenantIdClaim = "tenant_id";
    public const string PlanClaim = "plan";

    private readonly JwtSecurityTokenHandler _handler = new();
    private readonly ILogger<TenantResolver> _logger;

    public TenantResolver(ILogger<TenantResolver> logger) => _logger = logger;

    /// <summary>
    /// Decodes the bearer token and projects the tenant identity out of it.
    /// The token's signature has already been validated by the JWT bearer
    /// middleware before this runs, so this is a read-only decode.
    /// </summary>
    public TenantContext Resolve(HttpRequest request)
    {
        string authorizationHeader = request.Headers.Authorization.ToString();
        string bearerToken = ExtractBearerToken(authorizationHeader);

        JwtSecurityToken decodedJwt = _handler.ReadJwtToken(bearerToken);

        string? tenantId = ClaimValue(decodedJwt, TenantIdClaim);
        if (string.IsNullOrWhiteSpace(tenantId))
        {
            throw new TenantResolutionException(
                $"bearer token {decodedJwt.Id} carries no '{TenantIdClaim}' claim");
        }

        string plan = ClaimValue(decodedJwt, PlanClaim) ?? PlanCatalog.DefaultPlan;
        decimal unitPriceUsd = PlanCatalog.UnitPriceUsd(plan);

        TenantContext tenant = new(
            TenantId: tenantId,
            Plan: plan,
            UnitPriceUsd: unitPriceUsd,
            TokenSubject: decodedJwt.Subject ?? string.Empty,
            TokenId: decodedJwt.Id ?? string.Empty);

        _logger.LogDebug("resolved tenant context for batch on plan {Plan}", tenant.Plan);
        return tenant;
    }

    private static string ExtractBearerToken(string authorizationHeader)
    {
        if (string.IsNullOrWhiteSpace(authorizationHeader))
        {
            throw new TenantResolutionException("Authorization header is missing");
        }

        const string scheme = "Bearer ";
        if (!authorizationHeader.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
        {
            throw new TenantResolutionException("Authorization header is not a bearer token");
        }

        return authorizationHeader[scheme.Length..].Trim();
    }

    private static string? ClaimValue(JwtSecurityToken token, string claimType) =>
        token.Claims.FirstOrDefault(c => c.Type == claimType)?.Value;
}
