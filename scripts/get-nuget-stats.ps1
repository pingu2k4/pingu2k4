param([Parameter(Mandatory)][string]$Destination)

$ErrorActionPreference = 'Stop'
$index = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json' -TimeoutSec 30
$searchUrl = ($index.resources | Where-Object { $_.'@type' -eq 'SearchQueryService/3.5.0' } | Select-Object -First 1).'@id'
if (!$searchUrl) { throw 'NuGet search service was not found.' }
$search = Invoke-RestMethod -Uri ($searchUrl + '?q=owner%3Apingu2k4&take=1000&prerelease=true&semVerLevel=2.0.0') -TimeoutSec 60
if ($search.data.Count -ne $search.totalHits -or $search.totalHits -lt 19) { throw 'Incomplete NuGet package discovery.' }

$packages = @(
    foreach ($package in $search.data) {
        $page = Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/packages/$($package.id)" -SessionVariable gallerySession -TimeoutSec 60
        $table = $page.Content
        if ($table -match 'id="load-more-versions" data-url="([^"]+)"') {
            $url = 'https://www.nuget.org' + $Matches[1]
            $csrf = [regex]::Match($table, 'name="__RequestVerificationToken"[^>]*value="([^"]+)"').Groups[1].Value
            $table = (Invoke-WebRequest -UseBasicParsing -Uri $url -Method Post -Body @{__RequestVerificationToken=$csrf} -WebSession $gallerySession -TimeoutSec 60).Content
        }
        $rows = [regex]::Matches($table, '(?s)<tr class="(?:bg-brand-info )?version-row".*?</tr>')
        if ($rows.Count -ne $package.versions.Count) { throw "Incomplete NuGet version table: $($package.id)." }
        $counts = @($rows | ForEach-Object {
            $cells = [regex]::Matches($_.Value, '(?s)<td[^>]*>(.*?)</td>')
            [long](($cells[1].Groups[1].Value -replace '<[^>]+>', '' -replace ',', '').Trim())
        })
        [pscustomobject]@{id=$package.id; downloads=[long]($counts | Measure-Object -Sum).Sum}
    }
)
$result = [pscustomobject]@{fetchedAt=[DateTime]::UtcNow.ToString('o'); packages=$packages; total=[long]($packages.downloads | Measure-Object -Sum).Sum}
[IO.File]::WriteAllText($Destination, ($result | ConvertTo-Json -Depth 5))
Write-Output "$($packages.Count) packages; $($result.total) NuGet downloads."
