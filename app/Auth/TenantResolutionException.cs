namespace MultiTenantApi.Auth;

public sealed class TenantResolutionException : Exception
{
    public TenantResolutionException(string message) : base(message) { }
}
