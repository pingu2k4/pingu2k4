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
    if (($repo.archived -and !$project.allowArchived) -or $repo.private -or $null -eq $repo.stargazers_count) { throw "Invalid featured repo: $($project.repo)" }
    $downloads = [long]0
    foreach ($id in $project.packages) {
        $package = @($nuget.data | Where-Object { $_.id -eq $id })
        if ($package.Count -ne 1 -or $null -eq $package[0].totalDownloads) { throw "NuGet download data missing: $id" }
        $downloads += [long]$package[0].totalDownloads
    }
    $title = [Security.SecurityElement]::Escape($project.title)
    $category = $project.category
    if ($repo.archived) { $category += " $([char]0x00B7) ARCHIVED" }
    $category = [Security.SecurityElement]::Escape($category)
    $subtitle = [Security.SecurityElement]::Escape($project.subtitle)
    $lineOne = [Security.SecurityElement]::Escape($project.lines[0])
    $lineTwo = [Security.SecurityElement]::Escape($project.lines[1])
    $stars = ([long]$repo.stargazers_count).ToString('N0', $culture)
    $total = $downloads.ToString('N0', $culture)
    $packageLabel = if ($project.packages.Count -eq 1) { '1 package' } else { "$($project.packages.Count) packages" }
    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="350" height="240" viewBox="0 0 350 240" role="img" aria-labelledby="title desc">
  <title id="title">$title</title>
  <desc id="desc">$category. $lineOne $lineTwo $stars GitHub stars. $total NuGet downloads across $packageLabel.</desc>
  <rect x="0.5" y="0.5" width="349" height="239" rx="12" fill="#0E0D12" stroke="#4C1D2D"/>
  <path d="M12.5 .5A12 12 0 0 0 .5 12.5V227.5A12 12 0 0 0 12.5 239.5C8.5 239.5 6.5 234 6.5 227.5V12.5C6.5 6 8.5 .5 12.5 .5Z" fill="#DC143C"/>
  <g font-family="Segoe UI,Arial,sans-serif">
    <rect x="21" y="18" width="273" height="22" rx="5" fill="#2A101B"/>
    <text x="31" y="33" font-size="9" font-weight="700" letter-spacing=".8" fill="#FF6280">$category</text>
    <path d="M318 23h9v9m0-9-11 11" fill="none" stroke="#FF6280" stroke-width="1.4"/>
    <text x="22" y="76" font-size="30" font-weight="700" fill="#F4F1F5">$title</text>
    <text x="22" y="98" font-size="12" fill="#B4ABB5">$subtitle</text>
    <text x="22" y="126" font-size="14" fill="#F4F1F5">$lineOne</text>
    <text x="22" y="147" font-size="14" fill="#F4F1F5">$lineTwo</text>
    <rect x="22" y="165" width="132" height="57" rx="7" fill="#19131C"/>
    <rect x="166" y="165" width="162" height="57" rx="7" fill="#19131C"/>
    <path d="m40 180 2.2 4.5 5 .7-3.6 3.5.9 5-4.5-2.4-4.5 2.4.9-5L33 185.2l5-.7Z" fill="none" stroke="#FF6280" stroke-width="1.4"/>
    <path d="M184 180v10m-4-4 4 4 4-4M177 192v3h14v-3" fill="none" stroke="#FF6280" stroke-width="1.4"/>
    <text x="55" y="194" font-size="21" font-weight="700" fill="#F4F1F5">$stars</text>
    <text x="199" y="194" font-size="21" font-weight="700" fill="#F4F1F5">$total</text>
    <text x="33" y="212" font-size="10" fill="#B4ABB5">GitHub stars</text>
    <text x="177" y="212" font-size="9" fill="#B4ABB5">NuGet downloads $([char]0x00B7) $packageLabel</text>
  </g>
</svg>
"@
    [IO.File]::WriteAllText((Join-Path $output ($project.file + '.svg')), $svg)
    Write-Output "$($project.repo): $stars stars; $total downloads ($packageLabel)."
}
