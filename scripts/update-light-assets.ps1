$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
# Existing unsuffixed SVGs remain the dark sources, including mobile layouts.
$sources = @([regex]::Matches($readme, '(?:src|srcset)="(assets/(?:hero[^/]*|cards/[^/]+|projects/[^/]+|skills/[^/]+)\.svg)"') |
    ForEach-Object { $_.Groups[1].Value -replace '-themed\.svg$', '.svg' } | Where-Object { $_ -notlike '*-light.svg' } | Sort-Object -Unique)
if (!$sources.Count) { throw 'No README SVG sources found.' }
$palette = @{
    '#101014' = '#FFFFFF'; '#352027' = '#E2D5D8'
    '#24181C' = '#FFF1F2'; '#19191F' = '#F4F5F7'
    '#F1F1F3' = '#1F2328'; '#A4A4AE' = '#59636E'
    '#94949F' = '#59636E'; '#EF4444' = '#CF3038'
}
$brandTiles = @{
    blazor = '#512BD4'; cs = '#953CAD'; dotnet = '#512BD4'
    git = '#F03C2E'; linear = '#5E6AD2'; maui = '#512BD4'
    wpf = '#0877C5'; sass = '#CD6799'
}
foreach ($source in $sources) {
    $svg = [IO.File]::ReadAllText((Join-Path $root $source))
    $darkSvg = $svg
    $name = [IO.Path]::GetFileNameWithoutExtension($source)
    if ($source.StartsWith('assets/skills/')) {
        if ($brandTiles.ContainsKey($name)) {
            $brand = $brandTiles[$name]
            # Reverse white-on-brand tiles while preserving their vector paths.
            $svg = ([regex]::new($brand)).Replace($svg, '#F1F5F9', 1)
            $svg = [regex]::Replace($svg, '(?i)(fill|stroke)="(?:#fff(?:fff)?|white)"', { param($match) $match.Groups[1].Value + '="' + $brand + '"' })
            if ($name -eq 'wpf') { $svg = $svg.Replace('width="196" height="69" fill="#0877C5"', 'width="196" height="69" fill="#F1F5F9"') }
            if ($name -eq 'maui') { $svg = $svg.Replace('rx="9" fill="#512BD4"', 'rx="9" fill="#F1F5F9"') }
        } else {
            $svg = $svg.Replace('#242938', '#F1F5F9')
            if ($name -in @('codex', 't3code')) {
                $svg = [regex]::Replace($svg, '(?i)fill="(?:#000000|black)"', 'fill="#F1F5F9"')
                $svg = [regex]::Replace($svg, '(?i)fill="(?:#fff(?:fff)?|white)"', 'fill="#1F2328"')
            }
            if ($name -in @('railway', 'unity')) { $svg = [regex]::Replace($svg, '(?i)fill="(?:#fff(?:fff)?|white)"', 'fill="#1F2328"') }
            if ($name -eq 'esbuild') { $svg = $svg.Replace('#FFCF00', '#FFF4C2') }
        }
    } else {
        $svg = [regex]::Replace($svg, '#[0-9a-fA-F]{6}', { param($match)
            if ($palette.ContainsKey($match.Value)) { $palette[$match.Value] } else { $match.Value }
        })
    }
    # Validate before saving, and never write the original or any email asset.
    $null = [xml]$svg
    $destination = Join-Path $root ($source -replace '\.svg$', '-light.svg')
    [IO.File]::WriteAllText($destination, $svg)
    if ($name.EndsWith('-mobile')) {
        # GitHub rewrites theme source media attributes, discarding width
        # conditions. Keep mobile selection width-only and inherit GitHub's
        # CSS color-scheme inside a self-contained SVG instead.
        $opening = [regex]::Match($darkSvg, '\A<svg\b[^>]*>').Value
        $darkBody = [regex]::Replace($darkSvg, '\A<svg\b[^>]*>|</svg>\s*\z', '')
        $lightBody = [regex]::Replace($svg, '\A<svg\b[^>]*>|</svg>\s*\z', '')
        # IDs are document-wide, including those in hidden artwork.
        $lightBody = [regex]::Replace($lightBody, '(\bid=")([^"]+)(")', '${1}light-${2}${3}')
        $lightBody = $lightBody.Replace('url(#', 'url(#light-')
        $themed = $opening + '<style>.profile-light{display:none}@media(prefers-color-scheme:light){.profile-dark{display:none}.profile-light{display:inline}}</style><g class="profile-dark">' + $darkBody + '</g><g class="profile-light">' + $lightBody + '</g></svg>'
        $null = [xml]$themed
        [IO.File]::WriteAllText((Join-Path $root ($source -replace '\.svg$', '-themed.svg')), $themed)
    }
}
Write-Output "Generated $($sources.Count) light README SVGs. Dark sources and email artwork unchanged."
