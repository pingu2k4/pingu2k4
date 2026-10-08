$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$projects = Get-Content -Raw -Encoding UTF8 -LiteralPath "$PSScriptRoot/projects.json" | ConvertFrom-Json
$headers = @{ 'User-Agent' = 'Pingu-profile-cards'; Accept = 'application/vnd.github+json' }
if ($env:GH_TOKEN) { $headers.Authorization = 'Bearer ' + $env:GH_TOKEN }

$index = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json' -TimeoutSec 30
$searchUrl = ($index.resources | Where-Object { $_.'@type' -eq 'SearchQueryService/3.5.0' } | Select-Object -First 1).'@id'
if (!$searchUrl) { throw 'NuGet search service was not found.' }
$nuget = Invoke-RestMethod -Uri ($searchUrl + '?q=PinguApps&take=1000&prerelease=true&semVerLevel=2.0.0') -TimeoutSec 60
$culture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
$output = Join-Path $root 'assets/projects'
New-Item -ItemType Directory -Path $output -Force | Out-Null

foreach ($project in $projects) {
    $repo = Invoke-RestMethod -Headers $headers -Uri ('https://api.github.com/repos/PinguApps/' + $project.repo) -TimeoutSec 30
    if ($repo.archived -or $repo.private -or $null -eq $repo.stargazers_count) { throw "Invalid featured repo: $($project.repo)" }
    $downloads = [long]0
    foreach ($id in $project.packages) {
        $package = @($nuget.data | Where-Object { $_.id -eq $id })
        if ($package.Count -ne 1 -or $null -eq $package[0].totalDownloads) { throw "NuGet download data missing: $id" }
        $downloads += [long]$package[0].totalDownloads
    }
    $title = [Security.SecurityElement]::Escape($project.title)
    $subtitle = [Security.SecurityElement]::Escape($project.subtitle)
    $lineOne = [Security.SecurityElement]::Escape($project.lines[0])
    $lineTwo = [Security.SecurityElement]::Escape($project.lines[1])
    $stars = ([long]$repo.stargazers_count).ToString('N0', $culture)
    $total = $downloads.ToString('N0', $culture)
    $packageLabel = if ($project.packages.Count -eq 1) { '1 package' } else { "$($project.packages.Count) packages" }
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="350" height="232" viewBox="0 0 350 232" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$lineOne $lineTwo $stars GitHub stars. $total NuGet downloads across $packageLabel.</desc>
  <rect x="0.5" y="0.5" width="349" height="231" rx="12" fill="#101014" stroke="#352027"/>
  <path d="M13 1h324" stroke="#EF4444" stroke-width="2"/>
  <g font-family="Segoe UI,Arial,sans-serif">
    <circle cx="24" cy="26" r="3" fill="#EF4444"/>
    <text x="35" y="30" font-size="10" font-weight="700" letter-spacing="1.2" fill="#EF4444">$($project.category)</text>
    <path d="M318 22h10v10m0-10-12 12" fill="none" stroke="#A4A4AE" stroke-width="1.5"/>
    <text x="22" y="62" font-size="24" font-weight="700" fill="#F1F1F3">$title</text>
    <text x="22" y="82" font-size="12" fill="#A4A4AE">$subtitle</text>
    <text x="22" y="113" font-size="14" fill="#D1D1D9">$lineOne</text>
    <text x="22" y="134" font-size="14" fill="#D1D1D9">$lineTwo</text>
    <path d="M22 153h306" stroke="#352027"/>
    <path d="m29 173 2.5 5 5.5.8-4 3.9.9 5.5-4.9-2.6-4.9 2.6.9-5.5-4-3.9 5.5-.8Z" fill="none" stroke="#EF4444" stroke-width="1.5"/>
    <path d="M182 173v11m-4-4 4 4 4-4m-10 8v3h12v-3" fill="none" stroke="#EF4444" stroke-width="1.5"/>
    <text x="46" y="187" font-size="22" font-weight="700" fill="#F1F1F3">$stars</text>
    <text x="199" y="187" font-size="22" font-weight="700" fill="#F1F1F3">$total</text>
    <text x="46" y="206" font-size="11" fill="#A4A4AE">GitHub stars</text>
    <text x="199" y="206" font-size="11" fill="#A4A4AE">NuGet downloads</text>
    <text x="199" y="222" font-size="10" fill="#A4A4AE">$packageLabel</text>
  </g>
</svg>
"@
    [IO.File]::WriteAllText((Join-Path $output ($project.file + '.svg')), $svg)
    Write-Output "$($project.repo): $stars stars; $total downloads ($packageLabel)."
}
