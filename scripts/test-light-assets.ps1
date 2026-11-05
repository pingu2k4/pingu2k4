$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('light-assets-test-' + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
Copy-Item -LiteralPath "$root/assets", "$root/scripts", "$root/README.md" -Destination $testRoot -Recurse
try {
    $readme = [IO.File]::ReadAllText("$testRoot/README.md")
    $pictures = @([regex]::Matches($readme, '<picture>.*?</picture>', 'Singleline'))
    $images = @([regex]::Matches($readme, '<img\b'))
    if ($pictures.Count -ne $images.Count) { throw 'Every README image must have theme sources.' }
    $sources = @([regex]::Matches($readme, '<img src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $originals = @{}
    Get-ChildItem "$testRoot/assets" -File -Recurse | Where-Object Name -NotLike '*-light.svg' | ForEach-Object { $originals[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    & "$testRoot/scripts/update-light-assets.ps1"
    foreach ($picture in $pictures) {
        [xml]$xml = $picture.Value
        $dark = [string]$xml.picture.img.src
        if ($dark -like '*-light.svg') { throw 'Fallback must remain a dark source.' }
        $light = $dark -replace '\.svg$', '-light.svg'
        $nodes = @($xml.picture.source)
        if ($nodes[-1].media -ne '(prefers-color-scheme: light)' -or $nodes[-1].srcset -ne $light) { throw "Missing desktop light source: $dark" }
        if ($nodes.Count -gt 1) {
            if ($nodes.Count -ne 2 -or $nodes[0].media -notmatch '^\(max-width: \d+px\)$' -or $nodes[0].srcset -notlike '*-mobile-themed.svg') { throw "Mobile source must keep a width-only query: $dark" }
        }
    }
    $generated = @(Get-ChildItem "$testRoot/assets" -Filter '*-light.svg' -Recurse)
    if ($generated.Count -ne 38) { throw "Expected all 38 approved variants, got $($generated.Count)." }
    $hashes = @{}
    foreach ($file in $generated) {
        $darkPath = $file.FullName -replace '-light\.svg$', '.svg'
        $dark = [IO.File]::ReadAllText($darkPath)
        $light = [IO.File]::ReadAllText($file.FullName)
        $null = [xml]$light
        # The approved conversion changes only literal colours; layout, text,
        # statistics, accessibility descriptions and vector paths must survive.
        $pattern = '#[0-9a-fA-F]{3,8}\b|(?<==")(?:black|white)(?=")'
        if ([regex]::Replace($dark, $pattern, 'COLOR') -cne [regex]::Replace($light, $pattern, 'COLOR')) { throw "Artwork content or geometry changed: $($file.Name)" }
        $hashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    foreach ($path in $originals.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -ne $originals[$path]) { throw "Dark/email asset changed: $path" }
    }
    & "$testRoot/scripts/update-light-assets.ps1"
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -ne $hashes[$path]) { throw "Generation is not deterministic: $path" }
    }
    $wrappers = @(Get-ChildItem "$testRoot/assets" -Filter '*-themed.svg' -Recurse)
    if ($wrappers.Count -ne 4) { throw 'Expected four responsive theme wrappers.' }
    foreach ($file in $wrappers) {
        [xml]$xml = [IO.File]::ReadAllText($file.FullName)
        $ids = @($xml.SelectNodes('//*[@id]') | ForEach-Object { $_.id })
        if (($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw "Duplicate mobile SVG IDs: $($file.Name)" }
        if ($xml.svg.style -notlike '*@media(prefers-color-scheme:light)*') { throw 'Mobile wrapper must inherit the viewing theme.' }
    }
    # A later daily statistics refresh must reach the light output too.
    $path = "$testRoot/assets/cards/adoption.svg"
    $svg = [IO.File]::ReadAllText($path)
    [xml]$xml = $svg
    $count = $xml.SelectSingleNode("//*[local-name()='text' and @x='56' and @y='147']").InnerText
    [IO.File]::WriteAllText($path, $svg.Replace($count, '987,654'))
    & "$testRoot/scripts/update-light-assets.ps1"
    [xml]$xml = [IO.File]::ReadAllText("$testRoot/assets/cards/adoption-light.svg")
    if ($xml.SelectSingleNode("//*[local-name()='text' and @x='56' and @y='147']").InnerText -ne '987,654') { throw 'Daily statistics did not refresh in light artwork.' }
    Write-Output 'Light asset checks passed: 38 pairs, theme/mobile source order, SVG content and geometry, deterministic regeneration, refreshed statistics, unchanged dark/email assets.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -or (Split-Path $resolved -Leaf) -notlike 'light-assets-test-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
