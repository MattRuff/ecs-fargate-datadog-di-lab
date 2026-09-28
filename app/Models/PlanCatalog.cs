namespace MultiTenantApi.Models;

/// <summary>
/// Per-transaction price list. The tenant's plan arrives as a JWT claim, so the
/// only place the price is knowable at runtime is inside the request path.
/// </summary>
public static class PlanCatalog
{
    private static readonly Dictionary<string, decimal> UnitPrices = new(StringComparer.OrdinalIgnoreCase)
    {
        ["free"] = 0.000m,
        ["standard"] = 0.004m,
        ["business"] = 0.003m,
        ["enterprise"] = 0.002m,
    };

    public const string DefaultPlan = "standard";

    public static decimal UnitPriceUsd(string plan) =>
        UnitPrices.TryGetValue(plan, out var price) ? price : UnitPrices[DefaultPlan];

    public static bool IsKnown(string plan) => UnitPrices.ContainsKey(plan);
}
