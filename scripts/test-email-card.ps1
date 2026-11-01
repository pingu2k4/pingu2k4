$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('email-card-test-' + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($testRoot)
$nugetPath = Join-Path $testRoot 'nuget.json'
$calendarPath = Join-Path $testRoot 'calendar.json'
$destination = Join-Path $testRoot 'stats.svg'
$generator = Join-Path $PSScriptRoot 'update-email-card.ps1'
function Assert-Equal($Actual, $Expected, $Message) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Message`: expected $Expected, got $Actual." }
}
try {
    # A real rolling-year shape that includes leap day and spans 54 Monday-start weeks.
    $end = [DateTime]'2029-01-08'
    $start = $end.AddYears(-1).AddDays(1)
    $days = @(
        for ($date=$start; $date -le $end; $date=$date.AddDays(1)) {
            @{date=$date.ToString('yyyy-MM-dd');count=1}
        }
    )
    $calendar = @{start=$start.ToString('yyyy-MM-dd');end='2029-01-08';capturedAt='2029-01-08T10:00:00Z';days=$days;annual=366;lifetime=12345;years=@{'2028'=12337;'2029'=8};automationVerified=$true}
    $nuget = @{total=142846;packages=@(@{id='One';downloads=142800},@{id='Two';downloads=46});fetchedAt='2029-01-08T09:00:00Z'}
    $nuget | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $nugetPath
    $calendar | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $calendarPath
    & $generator -NuGetStatsPath $nugetPath -CalendarPath $calendarPath -Destination $destination
    [xml]$svg = Get-Content -Raw -LiteralPath $destination
    $description = $svg.SelectSingleNode("//*[local-name()='desc']").InnerText
    if (!$description.Contains('142,846 NuGet downloads across 2 published packages. 12,345 all-time') -or !$description.Contains('Updated 8 Jan 2029 UTC.')) {
        throw 'Email card must display exact source values and the capture date.'
    }
    $bars = $svg.SelectNodes("//*[local-name()='rect' and @class='week-bar']")
    Assert-Equal $bars.Count 54 'Leap-year boundary weeks'
    Assert-Equal (($bars | ForEach-Object { [long]$_.GetAttribute('data-count') } | Measure-Object -Sum).Sum) 366 'Graph must account for every rolling-year contribution once'
    $before = [IO.File]::ReadAllText($destination)
    # Fail closed instead of publishing a plausible but stale or incomplete image.
    foreach ($scenario in @('missing-day','duplicate-day','wrong-total','stale-input','missing-count')) {
        $invalid = $calendar | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        switch ($scenario) {
            'missing-day' { $invalid.days = @($invalid.days | Select-Object -Skip 1) }
            'duplicate-day' { $invalid.days[1].date = $invalid.days[0].date }
            'wrong-total' { $invalid.annual++ }
            'stale-input' { $invalid.capturedAt = '2029-01-07T10:00:00Z' }
            'missing-count' {
                # Dropping a zero-valued field must not become PowerShell's intrinsic Count=1.
                $invalid.days[0].count = 0
                $invalid.annual--
                $invalid.days[0].PSObject.Properties.Remove('count')
            }
        }
        $invalid | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $calendarPath
        $failed = $false
        try { & $generator -NuGetStatsPath $nugetPath -CalendarPath $calendarPath -Destination $destination } catch { $failed = $true }
        Assert-Equal $failed $true "Reject $scenario"
        Assert-Equal ([IO.File]::ReadAllText($destination)) $before "Preserve prior artwork after $scenario"
    }
    Write-Output 'Email card regression checks passed: exact totals, update date, leap-year history, weekly sums and failed-input preservation.'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -or (Split-Path $resolved -Leaf) -notlike 'email-card-test-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
