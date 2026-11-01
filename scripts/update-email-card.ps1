param(
    [Parameter(Mandatory)][string]$NuGetStatsPath,
    [string]$CalendarPath = (Join-Path $PSScriptRoot 'activity-calendar.json'),
    [string]$Destination = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets/email/stats.svg')
)

$ErrorActionPreference = 'Stop'
$nuget = Get-Content -Raw -Encoding UTF8 -LiteralPath $NuGetStatsPath | ConvertFrom-Json
$calendar = Get-Content -Raw -Encoding UTF8 -LiteralPath $CalendarPath | ConvertFrom-Json
$culture = [Globalization.CultureInfo]::GetCultureInfo('en-GB')
$invariant = [Globalization.CultureInfo]::InvariantCulture
function Format-Count($Value) { ([long]$Value).ToString('N0', $culture) }
function Format-Coordinate($Value) { $Value.ToString('0.###', $invariant) }

if ($null -eq $nuget.total -or $nuget.total -lt 0 -or !$nuget.packages.Count -or
    $nuget.total -ne ($nuget.packages.downloads | Measure-Object -Sum).Sum) {
    throw 'Incomplete NuGet statistics for the email card.'
}
$start = [DateTime]::ParseExact($calendar.start, 'yyyy-MM-dd', $invariant)
$end = [DateTime]::ParseExact($calendar.end, 'yyyy-MM-dd', $invariant)
if (!$calendar.automationVerified -or $calendar.days.Count -ne ($end - $start).Days + 1 -or
    $start -ne $end.AddYears(-1).AddDays(1) -or
    $calendar.annual -ne ($calendar.days | Measure-Object count -Sum).Sum -or
    $calendar.lifetime -ne ($calendar.years.psobject.Properties.Value | Measure-Object -Sum).Sum) {
    throw 'Incomplete contribution statistics for the email card.'
}
$captured = [DateTimeOffset]::Parse($calendar.capturedAt, $invariant)
$fetched = [DateTimeOffset]::Parse($nuget.fetchedAt, $invariant)
if ($captured.UtcDateTime.Date -ne $end -or $fetched.UtcDateTime.Date -ne $end) {
    throw 'Email card inputs must come from the same daily refresh.'
}
$weeks = [ordered]@{}
for ($i = 0; $i -lt $calendar.days.Count; $i++) {
    $day = $calendar.days[$i]
    $date = $start.AddDays($i)
    if (!$day.PSObject.Properties['count'] -or $day.date -ne $date.ToString('yyyy-MM-dd') -or $null -eq $day.count -or $day.count -lt 0) {
        throw 'Invalid contribution day in the email card.'
    }
    $monday = $date.AddDays(-(([int]$date.DayOfWeek + 6) % 7)).ToString('yyyy-MM-dd')
    $weeks[$monday] += [long]$day.count
}
$maximum = [Math]::Max(100, [Math]::Ceiling(($weeks.Values | Measure-Object -Maximum).Maximum / 100) * 100)
$step = 468 / $weeks.Count
$bars = [Text.StringBuilder]::new()
$i = 0
foreach ($week in $weeks.GetEnumerator()) {
    $height = $week.Value / $maximum * 62
    $x = Format-Coordinate (48 + $i * $step)
    $y = Format-Coordinate (194 - $height)
    $width = Format-Coordinate ($step * 0.75)
    $h = Format-Coordinate $height
    [void]$bars.AppendLine("<rect class=`"week-bar`" x=`"$x`" y=`"$y`" width=`"$width`" height=`"$h`" rx=`"1`" data-date=`"$($week.Key)`" data-count=`"$($week.Value)`"><title>Week of $($week.Key): $($week.Value) contributions</title></rect>")
    $i++
}
$downloads = Format-Count $nuget.total
$packages = Format-Count $nuget.packages.Count
$lifetime = Format-Count $calendar.lifetime
$annual = Format-Count $calendar.annual
$updated = $end.ToString('d MMM yyyy', $culture)
$first = $start.ToString('d MMM yyyy', $culture)
$last = $end.ToString('d MMM yyyy', $culture)
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="540" height="246" viewBox="0 0 540 246" role="img" aria-labelledby="title desc">
  <title id="title">PinguApps | Packages and GitHub activity</title>
  <desc id="desc">$downloads NuGet downloads across $packages published packages. $lifetime all-time GitHub profile contributions, including shared private counts. $annual contributions from $first to $last, grouped into Monday-start weeks; boundary weeks may be partial. Updated $updated UTC.</desc>
  <rect x=".5" y=".5" width="539" height="245" rx="12" fill="#101014" stroke="#352027"/>
  <path d="M12.5 .5A12 12 0 0 0 .5 12.5V233.5A12 12 0 0 0 12.5 245.5C8.5 245.5 6.5 240 6.5 233.5V12.5C6.5 6 8.5 .5 12.5 .5Z" fill="#EF4444"/>
  <g font-family="DejaVu Sans,Arial,sans-serif">
    <g font-size="26" font-weight="700" fill="#F1F1F3">
      <text x="24" y="43">$downloads</text><text x="194" y="43">$packages</text><text x="364" y="43">$lifetime</text>
    </g>
    <g font-size="18" fill="#A4A4AE">
      <text x="24" y="66">NuGet</text><text x="24" y="87">downloads</text>
      <text x="194" y="66">Published</text><text x="194" y="87">packages</text>
      <text x="364" y="66" font-size="16">All-time GitHub</text><text x="364" y="87">contributions</text>
      <text x="24" y="115" font-size="16" fill="#F1F1F3">Weekly contributions · past year</text>
    </g>
    <path d="M48 132H516M48 194H516" fill="none" stroke="#352027"/>
    <g font-size="14" fill="#A4A4AE" text-anchor="end"><text x="41" y="137">$maximum</text><text x="41" y="199">0</text></g>
    <g fill="#EF4444">$bars</g>
    <g font-size="16" fill="#A4A4AE"><text x="48" y="214">$first</text><text x="516" y="214" text-anchor="end">$last</text>
      <text x="24" y="237" font-size="18">Updated $updated UTC</text>
    </g>
  </g>
</svg>
"@
[void][IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($Destination)) -Parent))
[IO.File]::WriteAllText($Destination, $svg)
Write-Output "Email card: $downloads downloads; $packages packages; $lifetime all-time contributions; $($weeks.Count) weekly bars."
