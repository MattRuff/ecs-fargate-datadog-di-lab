using System.Collections.Concurrent;
using System.Diagnostics;
using MultiTenantApi.Models;

namespace MultiTenantApi.Processing;

/// <summary>
/// The "does something" part of the workload: takes a batch of line items for a
/// tenant, settles them, and returns what the tenant should be charged.
///
/// Also a useful second probe target — the tenant arrives here as a method
/// argument, one frame deeper than <see cref="Auth.TenantResolver"/>, which lets
/// you demo that a probe placed on business logic still tags the active span.
/// </summary>
public sealed class SettlementProcessor
{
    private readonly ConcurrentDictionary<string, SettlementResult> _ledger = new();
    private readonly ILogger<SettlementProcessor> _logger;

    public SettlementProcessor(ILogger<SettlementProcessor> logger) => _logger = logger;

    public async Task<SettlementResult> SettleAsync(
        TenantContext tenant,
        SettlementRequest request,
        CancellationToken cancellationToken = default)
    {
        if (request.Items.Count == 0)
        {
            throw new ArgumentException("settlement batch contains no line items", nameof(request));
        }

        var stopwatch = Stopwatch.StartNew();
        var settlementId = $"stl_{Guid.NewGuid():n}";

        int billableUnits = 0;
        decimal grossAmountUsd = 0m;

        foreach (var item in request.Items)
        {
            cancellationToken.ThrowIfCancellationRequested();

            // Stand-in for the real work: risk scoring, ledger writes, FX lookup.
            await Task.Delay(Random.Shared.Next(2, 12), cancellationToken);

            billableUnits += item.Quantity;
            grossAmountUsd += item.AmountUsd * item.Quantity;
        }

        // A deliberately flaky downstream so the lab produces some error traces.
        if (tenant.Plan.Equals("free", StringComparison.OrdinalIgnoreCase)
            && Random.Shared.NextDouble() < 0.15)
        {
            throw new InvalidOperationException(
                "settlement rejected: free plan batch quota exceeded");
        }

        stopwatch.Stop();

        var result = new SettlementResult(
            SettlementId: settlementId,
            TenantId: tenant.TenantId,
            BatchReference: request.BatchReference,
            BillableUnits: billableUnits,
            GrossAmountUsd: decimal.Round(grossAmountUsd, 2),
            BillableChargeUsd: decimal.Round(billableUnits * tenant.UnitPriceUsd, 4),
            ProcessingMillis: stopwatch.ElapsedMilliseconds);

        _ledger[settlementId] = result;
        _logger.LogInformation(
            "settled batch {BatchReference} with {BillableUnits} units in {Millis}ms",
            request.BatchReference, billableUnits, stopwatch.ElapsedMilliseconds);

        return result;
    }

    public SettlementResult? Lookup(string settlementId) =>
        _ledger.TryGetValue(settlementId, out var result) ? result : null;
}
