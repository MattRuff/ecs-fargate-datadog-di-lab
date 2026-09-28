namespace MultiTenantApi.Models;

/// <summary>Everything the application knows about the caller's tenant.</summary>
/// <remarks>
/// This object is built by <see cref="Auth.TenantResolver"/> from the JWT in the
/// Authorization header. It is the natural capture target for a Dynamic
/// Instrumentation probe: no Datadog SDK call appears anywhere in this repo.
/// </remarks>
public sealed record TenantContext(
    string TenantId,
    string Plan,
    decimal UnitPriceUsd,
    string TokenSubject,
    string TokenId);

public sealed record LineItem(string Sku, int Quantity, decimal AmountUsd);

public sealed record SettlementRequest(string BatchReference, List<LineItem> Items);

public sealed record SettlementResult(
    string SettlementId,
    string TenantId,
    string BatchReference,
    int BillableUnits,
    decimal GrossAmountUsd,
    decimal BillableChargeUsd,
    long ProcessingMillis);

public sealed record DevTokenRequest(string TenantId, string? Plan, int? TtlMinutes);

public sealed record DevTokenResponse(string AccessToken, string TokenType, int ExpiresInSeconds);
