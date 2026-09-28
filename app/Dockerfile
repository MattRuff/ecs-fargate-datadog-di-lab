# ---------- build ----------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY MultiTenantApi.csproj ./
RUN dotnet restore

COPY . ./
# Portable PDBs ship alongside the DLLs. Dynamic Instrumentation line probes
# cannot bind without them, so do not add --no-debug / DebugType=none here.
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

# ---------- runtime ----------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

# Datadog .NET tracer. Pinned so the lab is reproducible; bump deliberately.
ARG TRACER_VERSION=3.54.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSLo /tmp/datadog-dotnet-apm.deb \
      "https://github.com/DataDog/dd-trace-dotnet/releases/download/v${TRACER_VERSION}/datadog-dotnet-apm_${TRACER_VERSION}_amd64.deb" \
 && dpkg -i /tmp/datadog-dotnet-apm.deb \
 && rm -f /tmp/datadog-dotnet-apm.deb \
 && apt-get purge -y --auto-remove curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

RUN /opt/datadog/createLogPath.sh

# CLR profiler hooks. These are what make the tracer (and therefore Dynamic
# Instrumentation) load into the process without touching application code.
ENV CORECLR_ENABLE_PROFILING=1 \
    CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8} \
    CORECLR_PROFILER_PATH=/opt/datadog/Datadog.Trace.ClrProfiler.Native.so \
    DD_DOTNET_TRACER_HOME=/opt/datadog \
    LD_PRELOAD=/opt/datadog/continuousprofiler/Datadog.Linux.ApiWrapper.x64.so

WORKDIR /app
COPY --from=build /app/publish ./

ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_gcServer=1

EXPOSE 8080
ENTRYPOINT ["dotnet", "MultiTenantApi.dll"]
