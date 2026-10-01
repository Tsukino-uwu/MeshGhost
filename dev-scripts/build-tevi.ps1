# Builds MeshGhostTevi.dll (Release) from two clean clones of HEAD at different paths, refuses unless both are
# byte-identical, and stages it under packaging\release\games\tevi\MeshGhost\ with built-from.txt. build-tevi.bat
# runs this. Needs the .NET SDK global.json names and adapters\tevi\MeshGhostTevi\lib\*.dll from your TEVI install.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo 'adapters\tevi\MeshGhostTevi'
$gameDir = Join-Path $repo 'packaging\release\games\tevi'
$dest = Join-Path $gameDir 'MeshGhost'
# Every build input the staleness gates hash; a name with a slash is repo-relative.
$inputs = 'Plugin.cs', 'BridgeClient.cs', 'CoreLauncher.cs', 'MeshGhostTevi.csproj', 'packages.lock.json',
    './global.json', './Directory.Build.props', './nuget.config'

function Get-Sha256([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# What gets built is HEAD, never the working copy: a change not committed cannot reach the DLL.
$dirty = & git -C $repo status --porcelain --untracked-files=no -- 'adapters/tevi/MeshGhostTevi' 'global.json' 'Directory.Build.props' 'nuget.config'
if ($dirty) { throw "build inputs have uncommitted changes; the build uses HEAD, so commit first:`n$($dirty -join "`n")" }
$head = (& git -C $repo rev-parse HEAD).Trim()
foreach ($lib in 'Assembly-CSharp.dll', 'Newtonsoft.Json.dll') {
    if (-not (Test-Path -LiteralPath (Join-Path $src "lib\$lib"))) { throw "no lib\${lib}: copy it from your TEVI install (adapters\tevi\README.md)" }
}

# A git variable inherited from a hook would point every clone below at this repo.
foreach ($name in @(Get-ChildItem env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object Name)) {
    [Environment]::SetEnvironmentVariable($name, $null)
}
# NuGet over IPv4 only: a VPN that drops IPv6 fails the restore with NU1301 otherwise.
$env:DOTNET_SYSTEM_NET_DISABLEIPV6 = '1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "meshghost-tevi-build-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    $builds = @()
    foreach ($dir in (Join-Path $tmp 'a'), (Join-Path $tmp 'second\b')) {
        & git clone --quiet --no-local --no-hardlinks --no-checkout -- $repo $dir
        if ($LASTEXITCODE -ne 0) { throw "git clone into $dir failed" }
        & git -C $dir checkout --quiet --detach $head
        if ($LASTEXITCODE -ne 0) { throw "checkout of $head in $dir failed" }
        $cloneSrc = Join-Path $dir 'adapters\tevi\MeshGhostTevi'
        New-Item -ItemType Directory -Force (Join-Path $cloneSrc 'lib') | Out-Null
        Copy-Item (Join-Path $src 'lib\*.dll') (Join-Path $cloneSrc 'lib')
        # dotnet reads global.json from the working directory, so each build runs inside its clone.
        Push-Location $dir
        try {
            $sdk = (& dotnet --version).Trim()
            # PathMap puts /_/ where the clone's path would be; the full pdb stays, since ScriptEngine needs one.
            & dotnet build (Join-Path $cloneSrc 'MeshGhostTevi.csproj') -c Release "-p:PathMap=$dir=/_/" --nologo -v q | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "build in $dir failed ($LASTEXITCODE)" }
        }
        finally { Pop-Location }
        $dll = Join-Path $cloneSrc 'bin\Release\MeshGhostTevi.dll'
        $builds += [pscustomobject]@{ Sdk = $sdk; Dll = $dll; Hash = Get-Sha256 $dll }
    }
    $a, $b = $builds
    if ($a.Hash -ne $b.Hash) { throw "two clean builds of $head differ ($($a.Hash), $($b.Hash)): the build isn't reproducible" }
    if ($a.Sdk -ne $b.Sdk) { throw "the two builds used different SDKs ($($a.Sdk), $($b.Sdk))" }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($a.Dll))
    foreach ($p in $repo, [System.IO.Path]::GetTempPath(), $env:USERPROFILE) {
        if ($text.IndexOf($p, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "the fresh DLL still holds a local path: $p" }
    }
    Write-Output "two clean builds of $($head.Substring(0, 8)) at different paths: byte-identical (SDK $($a.Sdk))"

    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item $a.Dll (Join-Path $dest 'MeshGhostTevi.dll') -Force
    # The dev loop (tevi-hotreload.ps1) pairs the staged DLL with the pdb in the in-tree bin\Release: this build's.
    $devOut = Join-Path $src 'bin\Release'
    New-Item -ItemType Directory -Force $devOut | Out-Null
    foreach ($f in 'MeshGhostTevi.dll', 'MeshGhostTevi.pdb') { Copy-Item (Join-Path (Split-Path $a.Dll) $f) (Join-Path $devOut $f) -Force }

    $lines = @('# Written by dev-scripts\build-tevi.ps1; read by release.yml''s staleness gate and preflight. Do not hand-edit.',
        "commit: $head", "sdk: $($a.Sdk)")
    # Hashed in the clone that was built, so each file is in its committed, eol-pinned form.
    $built = Join-Path $tmp 'a'
    foreach ($name in $inputs) {
        $path = if ($name.Contains('/')) { Join-Path $built $name } else { Join-Path $built "adapters\tevi\MeshGhostTevi\$name" }
        $lines += "$($name): $(Get-Sha256 $path)"
    }
    $lines | Set-Content -LiteralPath (Join-Path $gameDir 'built-from.txt') -Encoding ascii
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
}
Write-Output "staged MeshGhostTevi.dll ($($a.Hash.Substring(0, 12))) from $($head.Substring(0, 8)); commit it with built-from.txt"
