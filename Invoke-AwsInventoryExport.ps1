<#
.SYNOPSIS
Exports AWS inventories for multiple credentialed clouds from a local cache.

.DESCRIPTION
The cache is a JSON file with a `clouds` array. Each entry is loaded one at a
time. Before each exporter run, the prior AWS environment variables are
removed and the current entry's variables are added. Credentials are not
printed, logged, or passed as command-line arguments.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CloudCachePath,

    [string]$ExporterPath = (Join-Path $PSScriptRoot 'aws_inventory_export.py'),

    [string]$DiagramScriptPath = (Join-Path $PSScriptRoot 'aws_architecture_diagram.py'),

    [string]$PythonCommand = 'python3',

    # By default exports remain beneath the directory that contains this script:
    # SCRIPTS/inventory/<CLOUD_NAME>/.
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'inventory'),

    [string[]]$Components
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EnvironmentNames = @(
    'AWS_ACCESS_KEY_ID',
    'AWS_SECRET_ACCESS_KEY',
    'AWS_SESSION_TOKEN',
    'AWS_SSO_START_URL',
    'AWS_SSO_REGION',
    'CLOUD_NAME'
)

function Clear-CloudEnvironment {
    foreach ($name in $EnvironmentNames) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Set-CloudEnvironment {
    param([Parameter(Mandatory)]$Cloud)

    # URL and SSO Region are cached even though the inventory AWS CLI calls use
    # the supplied temporary credentials directly.
    $env:AWS_SSO_START_URL = [string]$Cloud.url
    $env:AWS_SSO_REGION = [string]$Cloud.sso_region
    $env:CLOUD_NAME = [string]$Cloud.cloud_name
    $env:AWS_ACCESS_KEY_ID = [string]$Cloud.aws_access_key_id
    $env:AWS_SECRET_ACCESS_KEY = [string]$Cloud.aws_secret_access_key
    $env:AWS_SESSION_TOKEN = [string]$Cloud.aws_session_token
}

function Require-CloudFields {
    param([Parameter(Mandatory)]$Cloud)

    $required = @('url', 'sso_region', 'region', 'cloud_name', 'aws_access_key_id', 'aws_secret_access_key', 'aws_session_token')
    foreach ($field in $required) {
        $property = $Cloud.PSObject.Properties[$field]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Cloud cache entry is missing a value for '$field'."
        }
    }
    if ([string]$Cloud.cloud_name -match '[\\/]') {
        throw "CLOUD_NAME '$($Cloud.cloud_name)' cannot contain a slash or backslash."
    }
}

if (-not (Test-Path -LiteralPath $ExporterPath -PathType Leaf)) {
    throw "Python exporter was not found: $ExporterPath"
}
if (-not (Test-Path -LiteralPath $DiagramScriptPath -PathType Leaf)) {
    throw "Architecture diagram script was not found: $DiagramScriptPath"
}

$cache = Get-Content -LiteralPath $CloudCachePath -Raw | ConvertFrom-Json
$clouds = @($cache.clouds)
if ($clouds.Count -eq 0) {
    throw 'The cache contains no clouds.'
}
if ($clouds.Count -gt 50) {
    throw 'The cache contains more than 50 clouds; split it into separate runs.'
}

# Preserve any variables that existed before this PowerShell process started.
$originalEnvironment = @{}
foreach ($name in $EnvironmentNames) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    foreach ($cloud in $clouds) {
        Require-CloudFields -Cloud $cloud

        # This is deliberately at the top of every iteration: credentials from
        # one cloud can never carry into the next export.
        Clear-CloudEnvironment
        Set-CloudEnvironment -Cloud $cloud

        # Every cache entry supplies exactly one target AWS region. No shared
        # region list is accepted by this runner.
        $arguments = @(
            $ExporterPath,
            '--cloud', [string]$cloud.cloud_name,
            '--regions', [string]$cloud.region,
            '--output-dir', $OutputDirectory
        )
        if ($Components) {
            $arguments += '--components'
            $arguments += $Components
        }

        Write-Host "Exporting cloud '$($cloud.cloud_name)'..."
        & $PythonCommand @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "The Python exporter failed for cloud '$($cloud.cloud_name)' with exit code $LASTEXITCODE."
        }

        # Run the requested architecture diagram inside the same credential-isolated
        # cloud loop. The diagram and safe AWS CLI scaffold go beside the CSVs.
        & $PythonCommand $DiagramScriptPath '--cloud' $env:CLOUD_NAME '--output-dir' $OutputDirectory '--write-aws-cli'
        if ($LASTEXITCODE -ne 0) {
            throw "The architecture diagram script failed for cloud '$($cloud.cloud_name)' with exit code $LASTEXITCODE."
        }
    }
}
finally {
    # Remove the final cloud's credentials, then restore only values that were
    # present before this runner began.
    Clear-CloudEnvironment
    foreach ($name in $EnvironmentNames) {
        if ($null -ne $originalEnvironment[$name]) {
            Set-Item -Path "Env:$name" -Value $originalEnvironment[$name]
        }
    }
}
